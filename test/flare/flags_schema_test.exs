defmodule Flare.FlagsSchemaTest do
  use Flare.DataCase, async: true
  alias Flare.Accounts.Organization
  alias Flare.Projects.Project
  alias Flare.Flags.FeatureFlag

  test "flag kind validated and salt auto-generated" do
    {:ok, org} = Repo.insert(Organization.changeset(%Organization{}, %{name: "A", slug: "a"}))

    {:ok, proj} =
      Repo.insert(Project.changeset(%Project{}, %{name: "P", slug: "p", organization_id: org.id}))

    bad = FeatureFlag.changeset(%FeatureFlag{}, %{key: "x", kind: "nope", project_id: proj.id})
    refute bad.valid?

    {:ok, flag} =
      Repo.insert(
        FeatureFlag.changeset(%FeatureFlag{}, %{
          key: "payment_v2",
          kind: "boolean",
          project_id: proj.id
        })
      )

    assert is_binary(flag.rollout_salt)
    assert byte_size(flag.rollout_salt) > 0
  end
end
