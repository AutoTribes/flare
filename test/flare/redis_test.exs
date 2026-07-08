defmodule Flare.RedisTest do
  use ExUnit.Case, async: false

  test "redis round-trip" do
    assert Flare.Redis.command!(["PING"]) == "PONG"
    key = "flare:test:#{System.unique_integer([:positive])}"
    Flare.Redis.command!(["SET", key, "v"])
    assert Flare.Redis.command!(["GET", key]) == "v"
    Flare.Redis.command!(["DEL", key])
  end

  test "oban is configured with the repo" do
    cfg = Application.fetch_env!(:flare, Oban)
    assert cfg[:repo] == Flare.Repo
  end
end
