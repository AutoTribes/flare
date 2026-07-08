defmodule Flare.Sync.ConnectionRegistry do
  @moduledoc """
  ETS-backed registry mapping (sdk_key_id, conn_id) to SSE handler PIDs on this
  node, with a monotonic timestamp for eviction ordering. Ported from beacon.
  Node-local; cluster-wide counts would use Redis.
  """
  use GenServer

  @table :flare_sdk_connections

  def start_link(_opts), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @impl true
  def init(_) do
    :ets.new(@table, [:named_table, :public, :bag, read_concurrency: true])
    {:ok, %{}}
  end

  @spec register(String.t(), String.t(), pid()) :: :ok
  def register(sdk_key_id, conn_id, pid) do
    :ets.insert(@table, {{sdk_key_id, conn_id}, pid, System.monotonic_time(:millisecond)})
    :ok
  end

  @spec unregister(String.t(), String.t()) :: :ok
  def unregister(sdk_key_id, conn_id) do
    :ets.match_delete(@table, {{sdk_key_id, conn_id}, :_, :_})
    :ok
  end

  @spec lookup(String.t()) :: [{pid(), String.t()}]
  def lookup(sdk_key_id) do
    :ets.match(@table, {{sdk_key_id, :"$1"}, :"$2", :_})
    |> Enum.map(fn [conn_id, pid] -> {pid, conn_id} end)
  end

  @spec count() :: non_neg_integer()
  def count, do: :ets.info(@table, :size)

  @spec count_for(String.t()) :: non_neg_integer()
  def count_for(sdk_key_id) do
    :ets.select_count(@table, [{{{sdk_key_id, :"$1"}, :_, :_}, [], [true]}])
  end

  @doc "Evict the oldest connection for a key. Sends :conn_evicted, removes it. {:ok, pid} | :none."
  @spec evict_oldest(String.t()) :: {:ok, pid()} | :none
  def evict_oldest(sdk_key_id) do
    entries =
      :ets.match(@table, {{sdk_key_id, :"$1"}, :"$2", :"$3"})
      |> Enum.map(fn [conn_id, pid, at] -> {conn_id, pid, at} end)

    case Enum.sort_by(entries, fn {_, _, at} -> at end) do
      [] ->
        :none

      [{conn_id, pid, _} | _] ->
        :ets.match_delete(@table, {{sdk_key_id, conn_id}, pid, :_})
        send(pid, :conn_evicted)
        {:ok, pid}
    end
  end
end
