defmodule Flare.Flags do
  @moduledoc "Flags context. Owns flag CRUD, per-env settings, and ruleset assembly."
  import Ecto.Query
  alias Flare.Audit
  alias Flare.Evaluation.Ruleset
  alias Flare.Flags.{FeatureFlag, FeatureVariant, FlagEnvironmentSetting, FlagVersion}
  alias Flare.Projects.Environment
  alias Flare.Repo
  alias Flare.Segments
  alias Flare.Sync.RulesetCache

  def create_flag(%{variants: variants} = attrs) do
    attrs = Map.delete(attrs, :variants)

    Repo.transaction(fn ->
      {:ok, flag} = %FeatureFlag{} |> FeatureFlag.changeset(attrs) |> Repo.insert()

      Enum.each(variants, fn v ->
        {:ok, _} =
          %FeatureVariant{}
          |> FeatureVariant.changeset(%{
            feature_flag_id: flag.id,
            key: v.key,
            name: Map.get(v, :name),
            value: %{"v" => v.value}
          })
          |> Repo.insert()
      end)

      flag
    end)
  end

  def list_flags(project_id) do
    Repo.all(
      from f in FeatureFlag,
        where: f.project_id == ^project_id and is_nil(f.archived_at),
        order_by: [asc: f.key]
    )
  end

  def get_flag(id), do: Repo.get(FeatureFlag, id)

  def update_flag(%FeatureFlag{} = flag, attrs) do
    flag |> FeatureFlag.changeset(attrs) |> Repo.update()
  end

  def archive_flag(%FeatureFlag{} = flag) do
    flag
    |> FeatureFlag.changeset(%{archived_at: DateTime.utc_now() |> DateTime.truncate(:second)})
    |> Repo.update()
  end

  def upsert_env_setting(%FeatureFlag{id: fid}, %Environment{id: eid}, attrs) do
    attrs = Map.merge(attrs, %{feature_flag_id: fid, environment_id: eid})

    case Repo.get_by(FlagEnvironmentSetting, feature_flag_id: fid, environment_id: eid) do
      nil -> %FlagEnvironmentSetting{}
      existing -> existing
    end
    |> FlagEnvironmentSetting.changeset(attrs)
    |> Repo.insert_or_update()
  end

  @doc "Assemble a compiled Ruleset for an environment from the DB."
  def build_ruleset(%Environment{} = env) do
    project_id = Repo.one!(from e in Environment, where: e.id == ^env.id, select: e.project_id)
    segments = Segments.segment_map(project_id)

    flags =
      from(fs in FlagEnvironmentSetting,
        join: f in FeatureFlag,
        on: f.id == fs.feature_flag_id,
        where: fs.environment_id == ^env.id and is_nil(f.archived_at),
        preload: [feature_flag: :variants]
      )
      |> Repo.all()
      |> Enum.map(&to_flag_map/1)

    Ruleset.build(flags, segments, env.ruleset_version)
  end

  defp to_flag_map(%FlagEnvironmentSetting{feature_flag: flag} = fs) do
    variants =
      for v <- flag.variants, into: %{}, do: {v.key, v.value["v"]}

    %{
      key: flag.key,
      kind: flag.kind,
      salt: flag.rollout_salt,
      enabled: fs.enabled,
      rules: fs.rules,
      rollout: fs.rollout,
      default_variant: fs.default_variant_key,
      off_variant: fs.off_variant_key,
      variants: variants,
      targets: Map.get(fs.rules, "targets", %{}),
      bucket_by: Map.get(fs.rollout, "bucket_by", "user_id")
    }
  end

  @doc "JSON-serializable ruleset payload for SDKs. key_kind :server | :client | :mobile."
  def ruleset_payload(%Environment{} = env, key_kind \\ :server) do
    project_id = Repo.one!(from e in Environment, where: e.id == ^env.id, select: e.project_id)
    segments = Segments.segment_map(project_id)

    base =
      from(fs in FlagEnvironmentSetting,
        join: f in FeatureFlag,
        on: f.id == fs.feature_flag_id,
        where: fs.environment_id == ^env.id and is_nil(f.archived_at),
        preload: [feature_flag: :variants]
      )

    query =
      if key_kind in [:client, :mobile] do
        from([fs, f] in base, where: f.client_available == true)
      else
        base
      end

    flags = query |> Repo.all() |> Enum.map(&to_flag_payload/1)

    %{"version" => env.ruleset_version, "flags" => flags, "segments" => segments}
  end

  defp to_flag_payload(%FlagEnvironmentSetting{feature_flag: flag} = fs) do
    variants =
      for v <- flag.variants, into: %{}, do: {v.key, v.value["v"]}

    %{
      "key" => flag.key,
      "kind" => flag.kind,
      "salt" => flag.rollout_salt,
      "enabled" => fs.enabled,
      "rules" => fs.rules,
      "rollout" => fs.rollout,
      "default_variant" => fs.default_variant_key,
      "off_variant" => fs.off_variant_key,
      "variants" => variants,
      "targets" => Map.get(fs.rules, "targets", %{}),
      "bucket_by" => Map.get(fs.rollout, "bucket_by", "user_id")
    }
  end

  @doc """
  Update a flag's per-environment setting and publish the change:
  bump ruleset_version, write a flag_versions row, enqueue an audit log,
  refresh the Redis cache, and broadcast {:ruleset_updated, version}.
  Returns {:ok, new_version}.
  """
  def update_env_setting_and_publish(
        %FeatureFlag{} = flag,
        %Environment{} = env,
        attrs,
        actor \\ nil
      ) do
    result =
      Repo.transaction(fn ->
        {:ok, setting} = upsert_env_setting(flag, env, attrs)

        {1, _} =
          from(e in Environment, where: e.id == ^env.id)
          |> Repo.update_all(inc: [ruleset_version: 1])

        new_env = Repo.get!(Environment, env.id)
        version = new_env.ruleset_version
        snapshot = setting_snapshot(setting)

        {:ok, _fv} =
          %FlagVersion{}
          |> FlagVersion.changeset(%{
            feature_flag_id: flag.id,
            environment_id: env.id,
            version: version,
            snapshot: snapshot,
            change_type: "update",
            changed_by_id: actor && actor.id
          })
          |> Repo.insert()

        {:ok, _job} =
          Audit.log_async(%{
            organization_id: org_id_for_env(env),
            actor_id: actor && actor.id,
            action: "flag.setting.updated",
            entity_type: "flag_environment_setting",
            entity_id: setting.id,
            after: snapshot,
            metadata: %{"flag_key" => flag.key}
          })

        {new_env, version}
      end)

    case result do
      {:ok, {new_env, version}} ->
        RulesetCache.put(new_env, :server)
        RulesetCache.put(new_env, :client)
        Phoenix.PubSub.broadcast(Flare.PubSub, "env:#{env.id}", {:ruleset_updated, version})
        {:ok, version}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp setting_snapshot(setting) do
    %{
      "enabled" => setting.enabled,
      "rules" => setting.rules,
      "rollout" => setting.rollout,
      "default_variant_key" => setting.default_variant_key,
      "off_variant_key" => setting.off_variant_key
    }
  end

  defp org_id_for_env(%Environment{id: env_id}) do
    Repo.one!(
      from e in Environment,
        join: p in Flare.Projects.Project,
        on: p.id == e.project_id,
        where: e.id == ^env_id,
        select: p.organization_id
    )
  end
end
