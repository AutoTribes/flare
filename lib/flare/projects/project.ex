defmodule Flare.Projects.Project do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "projects" do
    field :name, :string
    field :slug, :string
    belongs_to :organization, Flare.Accounts.Organization
    has_many :environments, Flare.Projects.Environment
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(p, attrs) do
    p
    |> cast(attrs, [:name, :slug, :organization_id])
    |> validate_required([:name, :slug, :organization_id])
    |> validate_format(:slug, ~r/^[a-z0-9-]+$/)
    |> unique_constraint([:organization_id, :slug])
  end
end
