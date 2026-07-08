defmodule Flare.Sync.ConnectionRegistryTest do
  use ExUnit.Case, async: false
  alias Flare.Sync.ConnectionRegistry, as: Reg

  setup do
    # ConnectionRegistry is started by the application supervisor; ensure a clean slate per test
    :ets.delete_all_objects(:flare_sdk_connections)
    :ok
  end

  test "register and lookup" do
    Reg.register("key1", "conn-a", self())
    assert [{pid, "conn-a"}] = Reg.lookup("key1")
    assert pid == self()
  end

  test "unregister removes the entry" do
    Reg.register("key1", "conn-a", self())
    Reg.unregister("key1", "conn-a")
    assert Reg.lookup("key1") == []
  end

  test "count and count_for" do
    Reg.register("key1", "conn-a", self())
    Reg.register("key1", "conn-b", self())
    Reg.register("key2", "conn-c", self())
    assert Reg.count() == 3
    assert Reg.count_for("key1") == 2
    assert Reg.count_for("key2") == 1
  end

  test "evict_oldest sends :conn_evicted to the oldest pid and removes it" do
    parent = self()
    old = spawn(fn -> receive do: (m -> send(parent, {:got, :old, m})) end)
    Reg.register("key1", "conn-old", old)
    Process.sleep(5)
    new = spawn(fn -> receive do: (m -> send(parent, {:got, :new, m})) end)
    Reg.register("key1", "conn-new", new)

    assert {:ok, ^old} = Reg.evict_oldest("key1")
    assert_receive {:got, :old, :conn_evicted}, 1000
    # only the new one remains
    assert Reg.count_for("key1") == 1
  end

  test "evict_oldest on unknown key returns :none" do
    assert Reg.evict_oldest("nope") == :none
  end
end
