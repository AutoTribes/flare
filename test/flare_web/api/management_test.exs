defmodule FlareWeb.Api.ManagementTest do
  use FlareWeb.ConnCase, async: false
  alias Flare.{Accounts, Flags, Projects}

  setup %{conn: conn} do
    {:ok, org} = Accounts.create_organization(%{name: "A", slug: "a"})
    {:ok, %{plaintext: api_token}} = Projects.generate_api_key(org, %{"scopes" => ["admin"]})
    conn = put_req_header(conn, "authorization", "Bearer #{api_token}")
    %{org: org, conn: conn}
  end

  test "401 without api key" do
    conn = build_conn() |> get(~p"/api/projects")
    assert conn.status == 401
  end

  test "create + list projects", %{conn: conn} do
    conn2 = post(conn, ~p"/api/projects", %{"name" => "App", "slug" => "app"})
    assert conn2.status == 201
    pid = Jason.decode!(conn2.resp_body)["data"]["id"]
    assert is_binary(pid)

    listed = get(conn, ~p"/api/projects") |> then(&Jason.decode!(&1.resp_body)["data"])
    assert Enum.any?(listed, &(&1["id"] == pid))
  end

  test "create flag via API appears in the SDK ruleset", %{conn: conn, org: org} do
    {:ok, proj} = Projects.create_project(%{name: "P", slug: "p", organization_id: org.id})

    {:ok, env} =
      Projects.create_environment(%{name: "Prod", key: "production", project_id: proj.id})

    cflag =
      post(conn, ~p"/api/projects/#{proj.id}/flags", %{
        "key" => "new_flag",
        "kind" => "boolean",
        "variants" => [%{"key" => "on", "value" => true}, %{"key" => "off", "value" => false}]
      })

    assert cflag.status == 201
    flag_id = Jason.decode!(cflag.resp_body)["data"]["id"]

    # publish a setting via API
    Phoenix.PubSub.subscribe(Flare.PubSub, "env:#{env.id}")

    put_conn =
      put(conn, ~p"/api/flags/#{flag_id}/environments/#{env.id}/settings", %{
        "enabled" => true,
        "default_variant_key" => "on",
        "off_variant_key" => "off"
      })

    assert put_conn.status == 200
    assert Jason.decode!(put_conn.resp_body)["data"]["version"] == 1
    assert_receive {:ruleset_updated, 1}, 2000

    # confirm it shows up in the SDK ruleset endpoint
    {:ok, %{plaintext: sdk_token}} = Projects.generate_sdk_key(env, :server)

    rs =
      build_conn()
      |> put_req_header("authorization", "Bearer #{sdk_token}")
      |> get(~p"/sdk/ruleset")

    assert rs.status == 200
    assert Enum.any?(Jason.decode!(rs.resp_body)["flags"], &(&1["key"] == "new_flag"))
  end

  test "archive flag returns 204", %{conn: conn, org: org} do
    {:ok, proj} = Projects.create_project(%{name: "P2", slug: "p2", organization_id: org.id})

    {:ok, flag} =
      Flags.create_flag(%{
        project_id: proj.id,
        key: "temp",
        kind: "boolean",
        variants: [%{key: "on", value: true}, %{key: "off", value: false}]
      })

    conn = delete(conn, ~p"/api/flags/#{flag.id}")
    assert conn.status == 204
  end
end
