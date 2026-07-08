defmodule Flare.Accounts do
  @moduledoc "Accounts context."
  alias Flare.Repo
  alias Flare.Accounts.Organization

  def create_organization(attrs),
    do: %Organization{} |> Organization.changeset(attrs) |> Repo.insert()

  def get_organization!(id), do: Repo.get!(Organization, id)
end
