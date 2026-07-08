defmodule Flare.Sync.SSEHandler do
  @moduledoc """
  Per-connection SSE handler. Subscribes to the environment's PubSub topic and
  forwards realtime signals to the connection-owner process. Does NO datastore
  I/O — the owner (controller) reads the cache and writes to the socket.
  Ported/simplified from beacon's SSEHandler.

  Messages sent to conn_owner:
    {:ruleset_updated, version}  -> owner should write the current ruleset as an SSE `put`
    {:sse_chunk, iodata}         -> owner should write this raw chunk (heartbeat comment)
    {:sse_close, reason}         -> owner should end the connection
  """
  use GenServer, restart: :temporary
  require Logger
  alias Flare.Sync.ConnectionRegistry

  defstruct [
    :conn_owner,
    :sdk_key_id,
    :conn_id,
    :env_id,
    :last_version,
    :heartbeat_ms,
    :max_mailbox
  ]

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    state = %__MODULE__{
      conn_owner: Keyword.fetch!(opts, :conn_owner),
      sdk_key_id: Keyword.fetch!(opts, :sdk_key_id),
      conn_id: Keyword.fetch!(opts, :conn_id),
      env_id: Keyword.fetch!(opts, :env_id),
      last_version: Keyword.get(opts, :last_version),
      heartbeat_ms:
        Keyword.get(opts, :heartbeat_ms) || Application.get_env(:flare, :sse_heartbeat_ms, 25_000),
      max_mailbox:
        Keyword.get(opts, :max_mailbox) || Application.get_env(:flare, :sse_max_mailbox, 1_000)
    }

    Process.monitor(state.conn_owner)
    Phoenix.PubSub.subscribe(Flare.PubSub, "env:#{state.env_id}")
    ConnectionRegistry.register(state.sdk_key_id, state.conn_id, self())
    schedule_heartbeat(state)
    {:ok, state}
  end

  @impl true
  def handle_info({:ruleset_updated, version}, state) do
    {:message_queue_len, len} = Process.info(self(), :message_queue_len)

    if len > state.max_mailbox do
      Logger.warning("[SSEHandler] mailbox overloaded (#{len}) for key=#{state.sdk_key_id}")
      send(state.conn_owner, {:sse_close, :overloaded})
      {:stop, :normal, state}
    else
      send(state.conn_owner, {:ruleset_updated, version})
      {:noreply, %{state | last_version: version}}
    end
  end

  def handle_info(:heartbeat, state) do
    send(state.conn_owner, {:sse_chunk, ":\n\n"})
    schedule_heartbeat(state)
    {:noreply, state}
  end

  def handle_info(:conn_evicted, state) do
    send(state.conn_owner, {:sse_close, :evicted})
    {:stop, :normal, state}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, %{conn_owner: pid} = state) do
    {:stop, :normal, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    ConnectionRegistry.unregister(state.sdk_key_id, state.conn_id)
    :ok
  end

  defp schedule_heartbeat(state), do: Process.send_after(self(), :heartbeat, state.heartbeat_ms)
end
