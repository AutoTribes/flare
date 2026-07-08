defmodule Flare.Accounts do
  @moduledoc "Accounts context."
  alias Flare.Accounts.Organization
  alias Flare.Repo

  def create_organization(attrs),
    do: %Organization{} |> Organization.changeset(attrs) |> Repo.insert()

  def get_organization!(id), do: Repo.get!(Organization, id)
end
