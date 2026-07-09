defmodule FlareWeb.RateLimitTest do
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
        key: "f",
        kind: "boolean",
        variants: [%{key: "on", value: true}, %{key: "off", value: false}]
      })

    {:ok, _} =
      Flags.upsert_env_setting(flag, env, %{
        enabled: true,
        default_variant_key: "on",
        off_variant_key: "off"
      })

    {:ok, %{plaintext: token}} = Projects.generate_sdk_key(env, :server)
    %{token: token}
  end

  test "returns 429 after exceeding the limit", %{token: token} do
    prev = Application.get_env(:flare, :rate_limit)
    Application.put_env(:flare, :rate_limit, 3)
    on_exit(fn -> Application.put_env(:flare, :rate_limit, prev) end)

    reqs =
      for _ <- 1..5 do
        build_conn()
        |> put_req_header("authorization", "Bearer #{token}")
        |> get(~p"/sdk/ruleset")
        |> Map.get(:status)
      end

    assert Enum.count(reqs, &(&1 == 200)) == 3
    assert Enum.any?(reqs, &(&1 == 429))
    # 429 responses carry Retry-After
    limited =
      build_conn() |> put_req_header("authorization", "Bearer #{token}") |> get(~p"/sdk/ruleset")

    assert limited.status == 429
    assert [_ | _] = get_resp_header(limited, "retry-after")
  end
end
