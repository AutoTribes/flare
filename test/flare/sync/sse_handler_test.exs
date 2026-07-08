defmodule Flare.Sync.SSEHandlerTest do
  use ExUnit.Case, async: false
  alias Flare.Sync.{ConnectionRegistry, SSEHandler}

  setup do
    :ets.delete_all_objects(:flare_sdk_connections)
    env_id = "env-#{System.unique_integer([:positive])}"
    %{env_id: env_id, key_id: "key-#{System.unique_integer([:positive])}"}
  end

  defp start(opts) do
    base = [conn_owner: self(), conn_id: "c1", heartbeat_ms: 60_000, max_mailbox: 1_000]
    {:ok, pid} = SSEHandler.start_link(Keyword.merge(base, opts))
    pid
  end

  test "registers on start and unregisters on stop", %{env_id: env_id, key_id: key_id} do
    pid = start(env_id: env_id, sdk_key_id: key_id)
    assert ConnectionRegistry.count_for(key_id) == 1
    ref = Process.monitor(pid)
    GenServer.stop(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1000
    assert ConnectionRegistry.count_for(key_id) == 0
  end

  test "forwards ruleset_updated broadcast to the owner", %{env_id: env_id, key_id: key_id} do
    _pid = start(env_id: env_id, sdk_key_id: key_id)
    Phoenix.PubSub.broadcast(Flare.PubSub, "env:#{env_id}", {:ruleset_updated, 9})
    assert_receive {:ruleset_updated, 9}, 1000
  end

  test "heartbeat sends an SSE comment chunk to the owner", %{env_id: env_id, key_id: key_id} do
    _pid = start(env_id: env_id, sdk_key_id: key_id, heartbeat_ms: 30)
    assert_receive {:sse_chunk, ":\n\n"}, 1000
  end

  test "eviction closes the connection", %{env_id: env_id, key_id: key_id} do
    pid = start(env_id: env_id, sdk_key_id: key_id)
    ref = Process.monitor(pid)
    send(pid, :conn_evicted)
    assert_receive {:sse_close, :evicted}, 1000
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1000
  end

  test "mailbox overload closes the connection", %{env_id: env_id, key_id: key_id} do
    pid = start(env_id: env_id, sdk_key_id: key_id, max_mailbox: -1)
    ref = Process.monitor(pid)
    Phoenix.PubSub.broadcast(Flare.PubSub, "env:#{env_id}", {:ruleset_updated, 1})
    assert_receive {:sse_close, :overloaded}, 1000
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1000
  end

  test "stops when the owner dies", %{env_id: env_id, key_id: key_id} do
    owner = spawn(fn -> Process.sleep(50) end)

    {:ok, pid} =
      SSEHandler.start_link(
        conn_owner: owner,
        conn_id: "c1",
        env_id: env_id,
        sdk_key_id: key_id,
        heartbeat_ms: 60_000,
        max_mailbox: 1_000
      )

    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1000
  end
end
