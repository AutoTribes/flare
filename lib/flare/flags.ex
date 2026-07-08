defmodule Flare.Flags do
  @moduledoc "Flags context. Owns flag CRUD, per-env settings, and ruleset assembly."
  import Ecto.Query
  alias Flare.Evaluation.Ruleset
  alias Flare.Flags.{FeatureFlag, FeatureVariant, FlagEnvironmentSetting}
  alias Flare.Projects.Environment
  alias Flare.Repo
  alias Flare.Segments

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
end
