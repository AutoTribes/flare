defmodule FlareWeb.PageController do
  use FlareWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
