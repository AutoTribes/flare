defmodule Flare.Accounts.Membership do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "memberships" do
    belongs_to :user, Flare.Accounts.User
    belongs_to :organization, Flare.Accounts.Organization
    belongs_to :role, Flare.Accounts.Role
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(m, attrs) do
    m
    |> cast(attrs, [:user_id, :organization_id, :role_id])
    |> validate_required([:user_id, :organization_id])
    |> unique_constraint([:user_id, :organization_id])
  end
end
