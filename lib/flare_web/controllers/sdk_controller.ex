defmodule FlareWeb.SdkController do
  use FlareWeb, :controller
  alias Flare.Sync.{RulesetCache, SSEHandler}

  @doc "Full ruleset snapshot; supports ?version=N -> 304 when unchanged."
  def ruleset(conn, params) do
    env = conn.assigns.environment
    kind = conn.assigns.key_kind
    client_version = parse_int(params["version"])

    if client_version == env.ruleset_version do
      send_resp(conn, 304, "")
    else
      json = RulesetCache.get(env, kind)

      conn
      |> put_resp_header("etag", to_string(env.ruleset_version))
      |> put_resp_content_type("application/json")
      |> send_resp(200, json)
    end
  end

  @doc "SSE stream. Replays via Last-Event-ID (client version), then streams live updates."
  def stream(conn, _params) do
    env = conn.assigns.environment
    kind = conn.assigns.key_kind
    sdk_key = conn.assigns.sdk_key
    client_version = last_event_id(conn)

    conn =
      conn
      |> put_resp_header("content-type", "text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("connection", "keep-alive")
      |> send_chunked(200)

    conn_id = Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)

    # Subscribe BEFORE catch-up: if we read-then-subscribe, a publish landing in
    # between is lost forever (the catch-up read misses it and we were never
    # subscribed to receive the broadcast). Subscribing first can cause a
    # duplicate event (catch-up + a live event for the same version) — that's
    # fine, SDK reloads are idempotent.
    {:ok, _pid} =
      SSEHandler.start_link(
        conn_owner: self(),
        sdk_key_id: sdk_key.id,
        conn_id: conn_id,
        env_id: env.id,
        last_version: env.ruleset_version
      )

    conn = maybe_catch_up(conn, env, kind, client_version)

    stream_loop(conn, env, kind)
  end

  # --- pure helpers (unit-tested) ---

  @doc false
  def sse_event(type, id, data), do: "id: #{id}\nevent: #{type}\ndata: #{data}\n\n"

  defp stream_loop(conn, env, kind) do
    receive do
      {:ruleset_updated, v} ->
        json = RulesetCache.get(env, kind)
        write(conn, sse_event("put", v, json), env, kind)

      {:sse_chunk, data} ->
        write(conn, data, env, kind)

      {:sse_close, _reason} ->
        conn
    end
  end

  defp write(conn, data, env, kind) do
    case chunk(conn, data) do
      {:ok, conn} -> stream_loop(conn, env, kind)
      {:error, _} -> conn
    end
  end

  defp maybe_catch_up(conn, env, kind, client_version) do
    if is_nil(client_version) or env.ruleset_version > client_version do
      json = RulesetCache.get(env, kind)

      case chunk(conn, sse_event("put", env.ruleset_version, json)) do
        {:ok, conn} -> conn
        {:error, _} -> conn
      end
    else
      conn
    end
  end

  defp last_event_id(conn) do
    case Plug.Conn.get_req_header(conn, "last-event-id") do
      [v | _] -> parse_int(v)
      _ -> nil
    end
  end

  defp parse_int(nil), do: nil
  defp parse_int(v) when is_integer(v), do: v

  defp parse_int(v) when is_binary(v) do
    case Integer.parse(v) do
      {n, _} -> n
      :error -> nil
    end
  end
end
