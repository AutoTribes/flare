defmodule FlareWeb.Plugs.ApiAuth do
  @moduledoc "Authenticates an org API key from the Bearer header; assigns :api_key and :organization_id."
  import Plug.Conn
  alias Flare.Projects

  def init(opts), do: opts

  def call(conn, _opts) do
    with ["Bearer " <> token | _] <- get_req_header(conn, "authorization"),
         {:ok, api_key} <- Projects.verify_api_key(token) do
      conn
      |> assign(:api_key, api_key)
      |> assign(:organization_id, api_key.organization_id)
    else
      _ ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(401, Jason.encode!(%{error: "unauthorized"}))
        |> halt()
    end
  end
end
