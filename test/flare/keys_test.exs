defmodule Flare.KeysTest do
  use Flare.DataCase, async: true
  alias Flare.{Accounts, Projects}

  setup do
    {:ok, org} = Accounts.create_organization(%{name: "A", slug: "a"})
    {:ok, proj} = Projects.create_project(%{name: "P", slug: "p", organization_id: org.id})

    {:ok, env} =
      Projects.create_environment(%{name: "Prod", key: "production", project_id: proj.id})

    %{org: org, env: env}
  end

  test "generate + verify SDK key round-trip", %{env: env} do
    {:ok, %{sdk_key: sk, plaintext: token}} = Projects.generate_sdk_key(env, :server)
    assert sk.kind == "server"
    assert is_binary(token) and String.contains?(token, ".")
    assert sk.hashed_secret != token

    {:ok, verified} = Projects.verify_sdk_key(token)
    assert verified.id == sk.id
    assert verified.environment_id == env.id
  end

  test "wrong secret fails", %{env: env} do
    {:ok, %{plaintext: token}} = Projects.generate_sdk_key(env, :client)
    [prefix, _secret] = String.split(token, ".", parts: 2)
    assert Projects.verify_sdk_key(prefix <> ".wrongsecret") == {:error, :invalid}
  end

  test "unknown prefix fails without crashing" do
    assert Projects.verify_sdk_key("sdk-nope.whatever") == {:error, :invalid}
  end

  test "expired key fails", %{env: env} do
    {:ok, %{sdk_key: sk, plaintext: token}} = Projects.generate_sdk_key(env, :server)
    past = DateTime.utc_now() |> DateTime.add(-3600, :second)
    {:ok, _} = sk |> Ecto.Changeset.change(expires_at: past) |> Flare.Repo.update()
    assert Projects.verify_sdk_key(token) == {:error, :invalid}
  end

  test "generate + verify API key round-trip with permissions", %{org: org} do
    {:ok, %{api_key: ak, plaintext: token}} =
      Projects.generate_api_key(org, %{"scopes" => ["flags:write"]})

    assert ak.permissions == %{"scopes" => ["flags:write"]}
    {:ok, verified} = Projects.verify_api_key(token)
    assert verified.id == ak.id
  end
end
