defmodule FlareWeb.Api.FlagController do
  use FlareWeb, :controller
  alias Flare.{Flags, Projects}
  alias FlareWeb.Api.ProjectController

  def index(conn, %{"project_id" => project_id}) do
    case Projects.get_project(conn.assigns.organization_id, project_id) do
      nil ->
        conn |> put_status(404) |> json(%{error: "project not found"})

      %{} ->
        json(conn, %{data: Enum.map(Flags.list_flags(project_id), &flag_json/1)})
    end
  end

  def create(conn, %{"project_id" => project_id} = params) do
    case Projects.get_project(conn.assigns.organization_id, project_id) do
      nil ->
        conn |> put_status(404) |> json(%{error: "project not found"})

      %{} ->
        variants =
          Map.get(params, "variants", [])
          |> Enum.map(fn v -> %{key: v["key"], value: v["value"], name: v["name"]} end)

        attrs = %{
          project_id: project_id,
          key: params["key"],
          kind: params["kind"],
          description: params["description"],
          tags: params["tags"] || [],
          variants: variants
        }

        case Flags.create_flag(attrs) do
          {:ok, flag} ->
            conn |> put_status(201) |> json(%{data: flag_json(flag)})

          {:error, cs} ->
            conn |> put_status(422) |> json(%{errors: ProjectController.translate_errors(cs)})
        end
    end
  end

  def update(conn, %{"id" => id} = params) do
    case authz_flag(conn, id) do
      nil ->
        conn |> put_status(404) |> json(%{error: "flag not found"})

      flag ->
        attrs = Map.take(params, ["description", "tags"])

        case Flags.update_flag(flag, attrs) do
          {:ok, f} ->
            json(conn, %{data: flag_json(f)})

          {:error, cs} ->
            conn |> put_status(422) |> json(%{errors: ProjectController.translate_errors(cs)})
        end
    end
  end

  def archive(conn, %{"id" => id}) do
    case authz_flag(conn, id) do
      nil ->
        conn |> put_status(404) |> json(%{error: "flag not found"})

      flag ->
        {:ok, _} = Flags.archive_flag(flag)
        send_resp(conn, 204, "")
    end
  end

  # Ensure the flag's project belongs to the caller's org.
  defp authz_flag(conn, id) do
    with %{} = flag <- Flags.get_flag(id),
         %{} = _proj <- Projects.get_project(conn.assigns.organization_id, flag.project_id) do
      flag
    else
      _ -> nil
    end
  end

  defp flag_json(f),
    do: %{
      id: f.id,
      key: f.key,
      kind: f.kind,
      description: f.description,
      tags: f.tags,
      archived_at: f.archived_at
    }
end
