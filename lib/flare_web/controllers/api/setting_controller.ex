defmodule FlareWeb.Api.SettingController do
  use FlareWeb, :controller
  alias Flare.{Flags, Projects}

  # PUT /api/flags/:flag_id/environments/:environment_id/settings
  def update(conn, %{"flag_id" => flag_id, "environment_id" => env_id} = params) do
    with %{} = flag <- Flags.get_flag(flag_id),
         %{} = _proj <- Projects.get_project(conn.assigns.organization_id, flag.project_id),
         %{} = env <- Projects.get_environment(env_id) do
      attrs =
        Map.take(params, ["enabled", "rules", "rollout", "default_variant_key", "off_variant_key"])

      {:ok, version} = Flags.update_env_setting_and_publish(flag, env, atomize(attrs), nil)
      json(conn, %{data: %{version: version}})
    else
      _ -> conn |> put_status(404) |> json(%{error: "flag or environment not found"})
    end
  end

  defp atomize(map) do
    Map.new(map, fn {k, v} -> {String.to_existing_atom(k), v} end)
  end
end
