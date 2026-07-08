defmodule Flare.ProjectsSchemaTest do
  use Flare.DataCase, async: true
  alias Flare.Accounts.Organization
  alias Flare.Projects.{Project, Environment, SdkKey}

  setup do
    {:ok, org} = Repo.insert(Organization.changeset(%Organization{}, %{name: "A", slug: "a"}))
    {:ok, org: org}
  end

  test "environment defaults ruleset_version to 0", %{org: org} do
    {:ok, proj} =
      Repo.insert(Project.changeset(%Project{}, %{name: "P", slug: "p", organization_id: org.id}))

    {:ok, env} =
      Repo.insert(
        Environment.changeset(%Environment{}, %{
          name: "Prod",
          key: "production",
          project_id: proj.id
        })
      )

    assert env.ruleset_version == 0
  end

  test "sdk_key kind is validated" do
    cs =
      SdkKey.changeset(%SdkKey{}, %{
        kind: "bogus",
        prefix: "x",
        hashed_secret: "h",
        environment_id: Ecto.UUID.generate()
      })

    refute cs.valid?
  end

  test "org insert still works after re-adding has_many :projects", %{org: org} do
    assert org.id
  end
end
