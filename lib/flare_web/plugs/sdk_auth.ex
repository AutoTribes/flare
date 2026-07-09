defmodule FlareWeb.Plugs.SdkAuth do
  @moduledoc "Authenticates an SDK key from Bearer header or ?sdk_key= param; assigns environment + key kind."
  import Plug.Conn
  alias Flare.{Projects, Repo}
  alias Flare.Projects.Environment

  def init(opts), do: opts

  def call(conn, _opts) do
    with token when is_binary(token) <- extract_token(conn),
         {:ok, sdk_key} <- Projects.verify_sdk_key(token),
         %Environment{} = env <- Repo.get(Environment, sdk_key.environment_id) do
      conn
      |> assign(:sdk_key, sdk_key)
      |> assign(:environment, env)
      |> assign(:key_kind, String.to_existing_atom(sdk_key.kind))
    else
      _ -> unauthorized(conn)
    end
  end

  defp extract_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token | _] -> token
      _ -> conn.params["sdk_key"]
    end
  end

  defp unauthorized(conn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(401, Jason.encode!(%{error: "unauthorized"}))
    |> halt()
  end
end
