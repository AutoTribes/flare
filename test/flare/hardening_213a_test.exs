defmodule Flare.Hardening213aTest do
  use FlareWeb.ConnCase, async: false
  alias Flare.{Accounts, Flags, Projects}

  test "C2: cannot publish settings to another org's environment", %{conn: conn} do
    {:ok, org_a} =
      Accounts.create_organization(%{
        name: "A",
        slug: "org-a-#{System.unique_integer([:positive])}"
      })

    {:ok, org_b} =
      Accounts.create_organization(%{
        name: "B",
        slug: "org-b-#{System.unique_integer([:positive])}"
      })

    {:ok, %{plaintext: a_token}} = Projects.generate_api_key(org_a, %{})
    {:ok, proj_a} = Projects.create_project(%{name: "PA", slug: "pa", organization_id: org_a.id})

    {:ok, flag_a} =
      Flags.create_flag(%{
        project_id: proj_a.id,
        key: "fa",
        kind: "boolean",
        variants: [%{key: "on", value: true}, %{key: "off", value: false}]
      })

    {:ok, proj_b} = Projects.create_project(%{name: "PB", slug: "pb", organization_id: org_b.id})

    {:ok, env_b} =
      Projects.create_environment(%{name: "Prod", key: "production", project_id: proj_b.id})

    conn = put_req_header(conn, "authorization", "Bearer #{a_token}")

    resp =
      put(conn, ~p"/api/flags/#{flag_a.id}/environments/#{env_b.id}/settings", %{
        "enabled" => true,
        "default_variant_key" => "on",
        "off_variant_key" => "off"
      })

    assert resp.status == 404
    # org B's env version must be untouched
    assert Flare.Repo.get!(Flare.Projects.Environment, env_b.id).ruleset_version == 0
  end

  test "I4: last_used_at is not rewritten on rapid repeated verification" do
    {:ok, org} =
      Accounts.create_organization(%{
        name: "C",
        slug: "org-c-#{System.unique_integer([:positive])}"
      })

    {:ok, proj} = Projects.create_project(%{name: "P", slug: "p", organization_id: org.id})

    {:ok, env} =
      Projects.create_environment(%{name: "Prod", key: "production", project_id: proj.id})

    {:ok, %{plaintext: token, sdk_key: _sk}} = Projects.generate_sdk_key(env, :server)
    {:ok, k1} = Projects.verify_sdk_key(token)
    {:ok, k2} = Projects.verify_sdk_key(token)
    reloaded1 = Flare.Repo.get!(Flare.Projects.SdkKey, k1.id)
    reloaded2 = Flare.Repo.get!(Flare.Projects.SdkKey, k2.id)
    assert reloaded1.last_used_at == reloaded2.last_used_at
  end

  test "I5: client payload excludes segments not referenced by client-available flags" do
    {:ok, org} =
      Accounts.create_organization(%{
        name: "D",
        slug: "org-d-#{System.unique_integer([:positive])}"
      })

    {:ok, proj} = Projects.create_project(%{name: "P", slug: "p", organization_id: org.id})

    {:ok, env} =
      Projects.create_environment(%{name: "Prod", key: "production", project_id: proj.id})

    {:ok, _srv} =
      Flare.Segments.create_segment(%{
        project_id: proj.id,
        key: "srv_only",
        name: "S",
        rules: %{
          "op" => "and",
          "conditions" => [%{"attr" => "email", "operator" => "in", "values" => ["a@x.com"]}]
        }
      })

    {:ok, _beta} =
      Flare.Segments.create_segment(%{
        project_id: proj.id,
        key: "beta",
        name: "B",
        rules: %{
          "op" => "and",
          "conditions" => [%{"attr" => "role", "operator" => "equals", "values" => ["driver"]}]
        }
      })

    {:ok, flag} =
      Flags.create_flag(%{
        project_id: proj.id,
        key: "cf",
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

    client_segs = Map.keys(Flags.ruleset_payload(env, :client)["segments"])
    server_segs = Map.keys(Flags.ruleset_payload(env, :server)["segments"])
    assert "beta" in client_segs
    refute "srv_only" in client_segs
    assert "srv_only" in server_segs
  end
end
