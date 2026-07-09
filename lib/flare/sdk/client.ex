defmodule Flare.SDK.Client do
  @moduledoc """
  Reference Flare SDK client. Caches a compiled ruleset locally and evaluates
  flags with zero network per evaluation, using the same Flare.Evaluation engine
  as the server. Modes: :offline | :polling | :streaming.
  """
  use GenServer
  require Logger
  alias Flare.Evaluation
  alias Flare.Evaluation.{Context, Ruleset}

  defstruct [
    :base_url,
    :sdk_key,
    :mode,
    :ruleset,
    :version,
    :poll_interval,
    default_ctx: %{},
    subscribers: []
  ]

  # --- lifecycle ---
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))

  @impl true
  def init(opts) do
    state = %__MODULE__{
      base_url: opts[:base_url],
      sdk_key: opts[:sdk_key],
      mode: opts[:mode] || :streaming,
      default_ctx: opts[:context] || %{},
      poll_interval: opts[:poll_interval] || 30_000
    }

    state =
      case opts[:bootstrap] do
        nil -> if state.mode == :offline, do: state, else: initial_fetch(state)
        payload -> load(state, payload)
      end

    state = start_transport(state)
    {:ok, state}
  end

  # --- public API (facade-friendly) ---
  # credo:disable-for-next-line Credo.Check.Readability.PredicateFunctionNames
  def is_enabled(pid, flag, ctx \\ %{}), do: variation(pid, flag, ctx, false) == true

  def variation(pid, flag, ctx \\ %{}, default \\ nil),
    do: GenServer.call(pid, {:eval, flag, ctx, default})

  def json(pid, flag, ctx \\ %{}, default \\ nil), do: variation(pid, flag, ctx, default)
  def identify(pid, ctx) when is_map(ctx), do: GenServer.call(pid, {:identify, ctx})
  def refresh(pid), do: GenServer.call(pid, :refresh)
  def subscribe(pid, subscriber), do: GenServer.call(pid, {:subscribe, subscriber})
  def offline_mode(pid), do: GenServer.call(pid, :offline_mode)
  def bootstrap(pid, payload), do: GenServer.call(pid, {:bootstrap, payload})

  # --- callbacks ---
  @impl true
  def handle_call({:eval, flag, ctx, default}, _from, state) do
    {:reply, do_eval(state, flag, ctx, default), state}
  end

  def handle_call({:identify, ctx}, _from, state),
    do: {:reply, :ok, %{state | default_ctx: Map.merge(state.default_ctx, ctx)}}

  def handle_call({:subscribe, sub}, _from, state),
    do: {:reply, :ok, %{state | subscribers: [sub | state.subscribers]}}

  def handle_call({:bootstrap, payload}, _from, state),
    do: {:reply, :ok, load_and_notify(state, payload)}

  def handle_call(:offline_mode, _from, state), do: {:reply, :ok, %{state | mode: :offline}}

  def handle_call(:refresh, _from, state) do
    case poll_fetch(state) do
      {:ok, payload} -> {:reply, :ok, load_and_notify(state, payload)}
      :unchanged -> {:reply, :ok, state}
      {:error, _} = e -> {:reply, e, state}
    end
  end

  @impl true
  def handle_info(:poll, state) do
    state =
      case poll_fetch(state) do
        {:ok, payload} -> load_and_notify(state, payload)
        _ -> state
      end

    schedule_poll(state)
    {:noreply, state}
  end

  # {:sse_payload, payload} messages come from the streaming task (Task 2.11 exercises this)
  def handle_info({:sse_payload, payload}, state), do: {:noreply, load_and_notify(state, payload)}
  def handle_info(_msg, state), do: {:noreply, state}

  # --- internals ---
  defp do_eval(%{ruleset: nil}, _flag, _ctx, default), do: default

  defp do_eval(%{ruleset: rs, default_ctx: dctx}, flag, ctx, default) do
    context = Context.new(Map.merge(dctx, ctx))

    case Evaluation.evaluate(rs, flag, context) do
      %{reason: :flag_not_found} -> default
      %{value: value} -> value
    end
  end

  defp load(state, payload) do
    %{state | ruleset: Ruleset.from_payload(payload), version: payload["version"]}
  end

  defp load_and_notify(state, payload) do
    new_state = load(state, payload)
    Enum.each(new_state.subscribers, &send(&1, {:flare_updated, new_state.version}))
    new_state
  end

  defp start_transport(%{mode: :polling} = state), do: schedule_poll(state) && state
  defp start_transport(%{mode: :streaming} = state), do: start_stream(state)
  defp start_transport(state), do: state

  defp schedule_poll(state) do
    Process.send_after(self(), :poll, state.poll_interval)
    state
  end

  # HTTP: GET /sdk/ruleset (+ ?version= for polling). Uses Finch (Flare.Finch).
  defp initial_fetch(state) do
    case http_get_ruleset(state, nil) do
      {:ok, payload} -> load(state, payload)
      _ -> state
    end
  end

  defp poll_fetch(state), do: http_get_ruleset(state, state.version)

  defp http_get_ruleset(%{base_url: nil}, _v), do: {:error, :no_base_url}

  defp http_get_ruleset(state, version) do
    q = if version, do: "?version=#{version}", else: ""
    url = "#{state.base_url}/sdk/ruleset#{q}"
    headers = [{"authorization", "Bearer #{state.sdk_key}"}]

    case Finch.build(:get, url, headers) |> Finch.request(Flare.Finch) do
      {:ok, %Finch.Response{status: 200, body: body}} -> {:ok, Jason.decode!(body)}
      {:ok, %Finch.Response{status: 304}} -> :unchanged
      {:ok, %Finch.Response{status: s}} -> {:error, {:http, s}}
      {:error, reason} -> {:error, reason}
    end
  end

  # Streaming: spawn a task that opens the SSE stream and forwards {:sse_payload, payload}.
  # Fully exercised in Task 2.11 with a real server; kept minimal here.
  defp start_stream(%{base_url: nil} = state), do: state

  defp start_stream(state) do
    parent = self()
    url = "#{state.base_url}/sdk/stream"
    headers = [{"authorization", "Bearer #{state.sdk_key}"}]
    last = state.version

    headers = if last, do: [{"last-event-id", to_string(last)} | headers], else: headers

    spawn_link(fn -> stream_loop(parent, url, headers) end)
    state
  end

  defp stream_loop(parent, url, headers) do
    req = Finch.build(:get, url, headers)

    Finch.stream(req, Flare.Finch, "", fn
      {:data, chunk}, acc ->
        {events, rest} = parse_sse(acc <> chunk)
        Enum.each(events, fn data -> send(parent, {:sse_payload, Jason.decode!(data)}) end)
        rest

      _other, acc ->
        acc
    end)
  rescue
    _ -> :ok
  end

  # Parse complete SSE events (separated by blank line); return {list_of_data_strings, remainder}
  defp parse_sse(buffer) do
    parts = String.split(buffer, "\n\n")
    {complete, [rest]} = Enum.split(parts, -1)

    data =
      complete
      |> Enum.map(&extract_data/1)
      |> Enum.reject(&is_nil/1)

    {data, rest}
  end

  defp extract_data(event_block) do
    event_block
    |> String.split("\n")
    |> Enum.find_value(fn
      "data: " <> d -> d
      _ -> nil
    end)
  end
end
