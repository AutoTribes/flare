defmodule FlareWeb.Api.EnvironmentController do
  use FlareWeb, :controller
  alias Flare.Projects
  alias FlareWeb.Api.ProjectController

  def create(conn, %{"project_id" => project_id} = params) do
    case Projects.get_project(conn.assigns.organization_id, project_id) do
      nil ->
        conn |> put_status(404) |> json(%{error: "project not found"})

      %{} ->
        attrs = Map.merge(Map.drop(params, ["project_id"]), %{"project_id" => project_id})

        case Projects.create_environment(attrs) do
          {:ok, env} ->
            conn |> put_status(201) |> json(%{data: env_json(env)})

          {:error, cs} ->
            conn |> put_status(422) |> json(%{errors: ProjectController.translate_errors(cs)})
        end
    end
  end

  defp env_json(e),
    do: %{
      id: e.id,
      name: e.name,
      key: e.key,
      project_id: e.project_id,
      ruleset_version: e.ruleset_version
    }
end
