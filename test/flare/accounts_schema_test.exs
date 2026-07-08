defmodule Flare.AccountsSchemaTest do
  use Flare.DataCase, async: true
  alias Flare.Accounts.{Organization, User, Role}

  test "organization requires slug format" do
    cs = Organization.changeset(%Organization{}, %{name: "Acme", slug: "Bad Slug"})
    refute cs.valid?
    assert %{slug: _} = errors_on(cs)
  end

  test "valid organization persists" do
    {:ok, org} =
      Repo.insert(Organization.changeset(%Organization{}, %{name: "Acme", slug: "acme"}))

    assert org.id
  end

  test "role uniqueness per org" do
    {:ok, org} = Repo.insert(Organization.changeset(%Organization{}, %{name: "A", slug: "a"}))
    attrs = %{name: "admin", organization_id: org.id}
    {:ok, _} = Repo.insert(Role.changeset(%Role{}, attrs))
    {:error, cs} = Repo.insert(Role.changeset(%Role{}, attrs))
    assert %{organization_id: ["has already been taken"]} = errors_on(cs)
  end

  test "user email validated" do
    cs = User.changeset(%User{}, %{email: "nope"})
    refute cs.valid?
  end
end
