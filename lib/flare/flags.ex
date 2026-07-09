defmodule Flare.Flags do
  @moduledoc "Flags context. Owns flag CRUD, per-env settings, and ruleset assembly."
  require Logger
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

  @doc """
  JSON-serializable ruleset payload for SDKs. key_kind :server | :client | :mobile.

  NOTE: client/mobile payloads are served to world-readable SDK keys (embedded in
  browser/app bundles). We prune the segment map down to only the segments actually
  referenced by the flags emitted in that payload — sensitive targeting definitions
  (e.g. an internal "vip_customers" segment keyed on PII) must live on server-only
  keys, not leak to every client.
  """
  def ruleset_payload(%Environment{} = env, key_kind \\ :server) do
    project_id = Repo.one!(from e in Environment, where: e.id == ^env.id, select: e.project_id)
    all_segments = Segments.segment_map(project_id)

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

    segments =
      if key_kind in [:client, :mobile] do
        referenced = referenced_segments(flags, all_segments)
        Map.take(all_segments, MapSet.to_list(referenced))
      else
        all_segments
      end

    %{"version" => env.ruleset_version, "flags" => flags, "segments" => segments}
  end

  # Worklist/closure over segment references: seed from every emitted flag's rules,
  # then expand by scanning each newly-referenced segment's own rules for further
  # segment refs (segments can reference segments), until no new keys are found.
  defp referenced_segments(flags, all_segments) do
    seed =
      flags
      |> Enum.flat_map(fn flag -> collect_segment_refs(flag["rules"]) end)
      |> MapSet.new()

    expand_segment_refs(seed, MapSet.new(), all_segments)
  end

  defp expand_segment_refs(frontier, seen, all_segments) do
    new_keys = MapSet.difference(frontier, seen)

    if MapSet.size(new_keys) == 0 do
      seen
    else
      seen = MapSet.union(seen, new_keys)

      next_frontier =
        new_keys
        |> Enum.flat_map(&segment_refs_for_key(&1, all_segments))
        |> MapSet.new()

      expand_segment_refs(next_frontier, seen, all_segments)
    end
  end

  defp segment_refs_for_key(key, all_segments) do
    case Map.fetch(all_segments, key) do
      {:ok, rules} -> collect_segment_refs(rules)
      :error -> []
    end
  end

  # Walk a rule tree collecting every referenced segment key. Handles the
  # top-level flag-rule "list" shape (a list of %{"rule" => rule} entries),
  # boolean condition groups (%{"op" => _, "conditions" => [...]}), segment
  # leaves (%{"segment" => key}), and attribute leaves (%{"attr" => ...},
  # ignored).
  defp collect_segment_refs(%{"list" => entries}) when is_list(entries) do
    Enum.flat_map(entries, fn
      %{"rule" => rule} -> collect_segment_refs(rule)
      _ -> []
    end)
  end

  defp collect_segment_refs(%{"op" => _, "conditions" => conditions}) when is_list(conditions) do
    Enum.flat_map(conditions, &collect_segment_refs/1)
  end

  defp collect_segment_refs(%{"segment" => key}) when is_binary(key), do: [key]
  defp collect_segment_refs(%{"attr" => _}), do: []
  defp collect_segment_refs(_), do: []

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
        safe_cache_refresh(new_env)
        Phoenix.PubSub.broadcast(Flare.PubSub, "env:#{env.id}", {:ruleset_updated, version})
        {:ok, version}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Cache refresh is best-effort: SSE handlers/RulesetCache.get rebuild from the DB
  # on a cache miss, so a failed refresh self-heals. The broadcast must still fire
  # even if Redis is down.
  defp safe_cache_refresh(env) do
    RulesetCache.put(env, :server)
    RulesetCache.put(env, :client)
  rescue
    e ->
      Logger.error("[Flags] ruleset cache refresh failed: #{inspect(e)}")
      :error
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
