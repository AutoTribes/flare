defmodule FlareWeb.Plugs.RateLimit do
  @moduledoc """
  Fixed-window rate limiting keyed by the authenticated key id. Runs after auth.
  Redis counter per (key_id, time-window); on overflow returns 429 + Retry-After.
  """
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, opts) do
    case rate_key(conn) do
      nil -> conn
      id -> enforce(conn, id, opts)
    end
  end

  defp rate_key(conn) do
    cond do
      match?(%{id: _}, conn.assigns[:sdk_key]) -> "sdk:" <> conn.assigns.sdk_key.id
      match?(%{id: _}, conn.assigns[:api_key]) -> "api:" <> conn.assigns.api_key.id
      true -> nil
    end
  end

  defp enforce(conn, id, opts) do
    limit = opts[:limit] || Application.get_env(:flare, :rate_limit, 300)
    window = opts[:window] || Application.get_env(:flare, :rate_limit_window, 60)
    bucket = div(System.system_time(:second), window)
    key = "flare:rl:#{id}:#{bucket}"

    count = Flare.Redis.command!(["INCR", key])
    if count == 1, do: Flare.Redis.command!(["EXPIRE", key, window])

    if count > limit do
      conn
      |> put_resp_header("retry-after", to_string(window))
      |> put_resp_content_type("application/json")
      |> send_resp(429, Jason.encode!(%{error: "rate_limited"}))
      |> halt()
    else
      put_resp_header(conn, "x-ratelimit-remaining", to_string(max(limit - count, 0)))
    end
  end
end
