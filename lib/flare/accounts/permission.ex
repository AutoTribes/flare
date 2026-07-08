defmodule Flare.Accounts.Permission do
  use Ecto.Schema
  import Ecto.Changeset

  @scope_types ~w(org project environment)
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "permissions" do
    field :action, :string
    field :scope_type, :string, default: "org"
    field :scope_id, :binary_id
    belongs_to :role, Flare.Accounts.Role
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(p, attrs) do
    p
    |> cast(attrs, [:action, :scope_type, :scope_id, :role_id])
    |> validate_required([:action, :scope_type, :role_id])
    |> validate_inclusion(:scope_type, @scope_types)
  end
end
