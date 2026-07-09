defmodule FlareWeb.SdkControllerTest do
  use FlareWeb.ConnCase, async: false
  alias Flare.{Accounts, Flags, Projects}

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
        off_variant_key: "off"
      })

    {:ok, %{sdk_key: _sk, plaintext: token}} = Projects.generate_sdk_key(env, :server)
    env = Flare.Repo.get!(Flare.Projects.Environment, env.id)
    %{env: env, token: token}
  end

  test "401 without a key", %{conn: conn} do
    conn = get(conn, ~p"/sdk/ruleset")
    assert conn.status == 401
  end

  test "401 with a bad key", %{conn: conn} do
    conn = conn |> put_req_header("authorization", "Bearer sdk-bad.nope") |> get(~p"/sdk/ruleset")
    assert conn.status == 401
  end

  test "200 ruleset with body", %{conn: conn, token: token, env: env} do
    conn = conn |> put_req_header("authorization", "Bearer #{token}") |> get(~p"/sdk/ruleset")
    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert body["version"] == env.ruleset_version
    assert Enum.any?(body["flags"], &(&1["key"] == "payment_v2"))
    assert [etag] = get_resp_header(conn, "etag")
    assert etag == to_string(env.ruleset_version)
  end

  test "304 when version matches", %{conn: conn, token: token, env: env} do
    conn =
      conn
      |> put_req_header("authorization", "Bearer #{token}")
      |> get(~p"/sdk/ruleset?version=#{env.ruleset_version}")

    assert conn.status == 304
  end

  test "200 when version is stale", %{conn: conn, token: token} do
    conn =
      conn
      |> put_req_header("authorization", "Bearer #{token}")
      |> get(~p"/sdk/ruleset?version=-1")

    assert conn.status == 200
  end

  test "sse_event formatting" do
    assert FlareWeb.SdkController.sse_event("put", 7, "{}") == "id: 7\nevent: put\ndata: {}\n\n"
  end
end
