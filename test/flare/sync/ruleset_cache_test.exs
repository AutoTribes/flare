defmodule Flare.Sync.RulesetCacheTest do
  use Flare.DataCase, async: false
  alias Flare.{Accounts, Evaluation, Flags, Projects, Segments}
  alias Flare.Evaluation.{Context, Ruleset}
  alias Flare.Sync.RulesetCache

  setup do
    {:ok, org} = Accounts.create_organization(%{name: "A", slug: "a"})
    {:ok, proj} = Projects.create_project(%{name: "P", slug: "p", organization_id: org.id})

    {:ok, env} =
      Projects.create_environment(%{name: "Prod", key: "production", project_id: proj.id})

    {:ok, flag} =
      Flags.create_flag(%{
        project_id: proj.id,
        key: "payment_v2",
        kind: "boolean",
        variants: [%{key: "on", value: true}, %{key: "off", value: false}]
      })

    {:ok, _} =
      Flags.upsert_env_setting(flag, env, %{
        enabled: true,
        default_variant_key: "on",
        off_variant_key: "off",
        rules: %{
          "list" => [
            %{
              "id" => "r1",
              "rule" => %{"attr" => "country", "operator" => "equals", "values" => ["KE"]},
              "variant" => "off"
            }
          ]
        }
      })

    %{org: org, proj: proj, env: env, flag: flag}
  end

  test "ruleset_payload is JSON-serializable with string keys", %{env: env} do
    payload = Flags.ruleset_payload(env)
    json = Jason.encode!(payload)
    decoded = Jason.decode!(json)
    assert decoded["version"] == env.ruleset_version
    assert is_list(decoded["flags"])
    assert hd(decoded["flags"])["key"] == "payment_v2"
    assert is_map(decoded["segments"])
  end

  test "from_payload -> build -> evaluate matches DB-built ruleset (JSON round-trip)", %{env: env} do
    payload = Flags.ruleset_payload(env) |> Jason.encode!() |> Jason.decode!()
    rs = Ruleset.from_payload(payload)
    d_ke = Evaluation.evaluate(rs, "payment_v2", Context.new(%{user_id: "u", country: "KE"}))
    d_ug = Evaluation.evaluate(rs, "payment_v2", Context.new(%{user_id: "u", country: "UG"}))
    assert d_ke.variant == "off"
    assert d_ug.variant == "on"
  end

  test "segment inlining survives JSON round-trip", %{proj: proj, env: env} do
    {:ok, _} =
      Segments.create_segment(%{
        project_id: proj.id,
        key: "beta",
        name: "Beta",
        rules: %{
          "op" => "and",
          "conditions" => [%{"attr" => "role", "operator" => "equals", "values" => ["driver"]}]
        }
      })

    {:ok, f2} =
      Flags.create_flag(%{
        project_id: proj.id,
        key: "f2",
        kind: "boolean",
        variants: [%{key: "on", value: true}, %{key: "off", value: false}]
      })

    {:ok, _} =
      Flags.upsert_env_setting(f2, env, %{
        enabled: true,
        default_variant_key: "off",
        off_variant_key: "off",
        rules: %{
          "list" => [
            %{"id" => "r1", "rule" => %{"segment" => "beta"}, "variant" => "on"}
          ]
        }
      })

    rs =
      Flags.ruleset_payload(env) |> Jason.encode!() |> Jason.decode!() |> Ruleset.from_payload()

    d = Evaluation.evaluate(rs, "f2", Context.new(%{user_id: "u", role: "driver"}))
    assert d.variant == "on"
  end

  test "client key filtering excludes client_available=false flags", %{proj: proj, env: env} do
    {:ok, hidden} =
      Flags.create_flag(%{
        project_id: proj.id,
        key: "server_only",
        kind: "boolean",
        variants: [%{key: "on", value: true}, %{key: "off", value: false}]
      })

    {:ok, _} = hidden |> Ecto.Changeset.change(client_available: false) |> Flare.Repo.update()

    {:ok, _} =
      Flags.upsert_env_setting(hidden, env, %{
        enabled: true,
        default_variant_key: "on",
        off_variant_key: "off"
      })

    server_keys = Flags.ruleset_payload(env, :server)["flags"] |> Enum.map(& &1["key"])
    client_keys = Flags.ruleset_payload(env, :client)["flags"] |> Enum.map(& &1["key"])
    assert "server_only" in server_keys
    refute "server_only" in client_keys
    assert "payment_v2" in client_keys
  end

  test "cache put then get returns identical payload", %{env: env} do
    put_json = RulesetCache.put(env, :server)
    got_json = RulesetCache.get(env, :server)
    assert Jason.decode!(put_json) == Jason.decode!(got_json)
  end
end
