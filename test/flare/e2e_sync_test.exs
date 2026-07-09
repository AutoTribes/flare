defmodule Flare.E2ESyncTest do
  use ExUnit.Case, async: false
  alias Flare.{Accounts, Flags, Projects, SDK}

  @base "http://127.0.0.1:4002"

  setup do
    # Shared sandbox: all processes (server handlers, SDK client, stream task) use this connection.
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Flare.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Flare.Repo, {:shared, self()})

    {:ok, org} =
      Accounts.create_organization(%{name: "A", slug: "a-#{System.unique_integer([:positive])}"})

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

    # initial: enabled, default on
    {:ok, 1} =
      Flags.update_env_setting_and_publish(
        flag,
        env,
        %{enabled: true, default_variant_key: "on", off_variant_key: "off"},
        nil
      )

    {:ok, %{plaintext: token}} = Projects.generate_sdk_key(env, :server)
    env = Flare.Repo.get!(Flare.Projects.Environment, env.id)

    %{env: env, flag: flag, token: token}
  end

  # Poll a fun until it returns truthy or the deadline passes.
  defp eventually(fun, timeout \\ 5000, interval \\ 50) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_eventually(fun, deadline, interval)
  end

  defp do_eventually(fun, deadline, interval) do
    case fun.() do
      x when x not in [nil, false] ->
        x

      _ ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(interval)
          do_eventually(fun, deadline, interval)
        else
          fun.()
        end
    end
  end

  test "POLLING: SDK picks up a flag change via refresh", %{env: env, flag: flag, token: token} do
    {:ok, c} =
      SDK.start_link(
        base_url: @base,
        sdk_key: token,
        mode: :polling,
        poll_interval: 60_000,
        context: %{user_id: "u1"}
      )

    # initial bootstrap fetched over HTTP
    assert eventually(fn -> SDK.variation(c, "payment_v2", %{}) == true end)

    # flip default to off
    {:ok, 2} =
      Flags.update_env_setting_and_publish(
        flag,
        env,
        %{enabled: true, default_variant_key: "off", off_variant_key: "off"},
        nil
      )

    :ok = SDK.refresh(c)
    assert SDK.variation(c, "payment_v2", %{}) == false
  end

  test "STREAMING: SDK receives a live update over SSE", %{env: env, flag: flag, token: token} do
    {:ok, c} =
      SDK.start_link(base_url: @base, sdk_key: token, mode: :streaming, context: %{user_id: "u1"})

    SDK.subscribe(c, self())
    # wait until the initial catch-up has loaded the ruleset over the live socket
    assert eventually(fn -> SDK.variation(c, "payment_v2", %{}) == true end)

    # publish a change; the SDK should reflect it via the stream without a manual refresh
    {:ok, 2} =
      Flags.update_env_setting_and_publish(
        flag,
        env,
        %{enabled: true, default_variant_key: "off", off_variant_key: "off"},
        nil
      )

    assert eventually(fn -> SDK.variation(c, "payment_v2", %{}) == false end, 8000)
  end
end
