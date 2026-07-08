defmodule Flare.Accounts.Role do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "roles" do
    field :name, :string
    field :builtin, :boolean, default: false
    belongs_to :organization, Flare.Accounts.Organization
    has_many :permissions, Flare.Accounts.Permission
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(role, attrs) do
    role
    |> cast(attrs, [:name, :builtin, :organization_id])
    |> validate_required([:name, :organization_id])
    |> unique_constraint([:organization_id, :name])
  end
end
