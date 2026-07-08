defmodule Flare.Sync.RulesetCache do
  @moduledoc "Redis-backed cache of the JSON ruleset payload per (environment, key kind)."
  alias Flare.{Flags, Redis}
  alias Flare.Projects.Environment

  def cache_key(env_id, kind), do: "flare:ruleset:#{env_id}:#{kind}"

  @doc "Build the payload, cache it, return the JSON string."
  def put(%Environment{} = env, kind) do
    json = env |> Flags.ruleset_payload(kind) |> Jason.encode!()
    Redis.command!(["SET", cache_key(env.id, kind), json])
    json
  end

  @doc "Return cached JSON string, rebuilding + caching on a miss."
  def get(%Environment{} = env, kind) do
    case Redis.command!(["GET", cache_key(env.id, kind)]) do
      nil -> put(env, kind)
      json -> json
    end
  end
end
