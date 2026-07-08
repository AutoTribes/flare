defmodule Flare.FlagsContextTest do
  use Flare.DataCase, async: true
  alias Flare.{Accounts, Evaluation, Flags, Projects, Segments}
  alias Flare.Evaluation.Context

  setup do
    {:ok, org} = Accounts.create_organization(%{name: "Acme", slug: "acme"})
    {:ok, proj} = Projects.create_project(%{name: "App", slug: "app", organization_id: org.id})

    {:ok, env} =
      Projects.create_environment(%{name: "Prod", key: "production", project_id: proj.id})

    %{org: org, proj: proj, env: env}
  end

  test "create flag, set env behavior, build ruleset, evaluate", %{proj: proj, env: env} do
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

    ruleset = Flags.build_ruleset(env)
    d_ke = Evaluation.evaluate(ruleset, "payment_v2", Context.new(%{user_id: "u", country: "KE"}))

    d_other =
      Evaluation.evaluate(ruleset, "payment_v2", Context.new(%{user_id: "u", country: "UG"}))

    assert d_ke.variant == "off"
    assert d_other.variant == "on"
  end

  test "segment reference resolves in built ruleset", %{proj: proj, env: env} do
    {:ok, _seg} =
      Segments.create_segment(%{
        project_id: proj.id,
        key: "beta",
        name: "Beta",
        rules: %{
          "op" => "and",
          "conditions" => [%{"attr" => "role", "operator" => "equals", "values" => ["driver"]}]
        }
      })

    {:ok, flag} =
      Flags.create_flag(%{
        project_id: proj.id,
        key: "f2",
        kind: "boolean",
        variants: [%{key: "on", value: true}, %{key: "off", value: false}]
      })

    {:ok, _} =
      Flags.upsert_env_setting(flag, env, %{
        enabled: true,
        default_variant_key: "off",
        off_variant_key: "off",
        rules: %{"list" => [%{"id" => "r1", "rule" => %{"segment" => "beta"}, "variant" => "on"}]}
      })

    rs = Flags.build_ruleset(env)
    d = Evaluation.evaluate(rs, "f2", Context.new(%{user_id: "u", role: "driver"}))
    assert d.variant == "on"
  end
end
