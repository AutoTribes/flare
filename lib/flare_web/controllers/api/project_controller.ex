defmodule FlareWeb.Api.ProjectController do
  use FlareWeb, :controller
  alias Flare.Projects

  def index(conn, _params) do
    projects = Projects.list_projects(conn.assigns.organization_id)
    json(conn, %{data: Enum.map(projects, &project_json/1)})
  end

  def create(conn, params) do
    attrs = Map.merge(params, %{"organization_id" => conn.assigns.organization_id})

    case Projects.create_project(attrs) do
      {:ok, p} -> conn |> put_status(201) |> json(%{data: project_json(p)})
      {:error, cs} -> conn |> put_status(422) |> json(%{errors: translate_errors(cs)})
    end
  end

  defp project_json(p),
    do: %{id: p.id, name: p.name, slug: p.slug, organization_id: p.organization_id}

  def translate_errors(cs), do: Ecto.Changeset.traverse_errors(cs, fn {msg, _} -> msg end)
end
