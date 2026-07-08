defmodule Flare.Projects do
  @moduledoc "Projects context."
  alias Flare.Projects.{Environment, Project}
  alias Flare.Repo

  def create_project(attrs), do: %Project{} |> Project.changeset(attrs) |> Repo.insert()

  def create_environment(attrs),
    do: %Environment{} |> Environment.changeset(attrs) |> Repo.insert()

  def get_environment!(id), do: Repo.get!(Environment, id)
end
