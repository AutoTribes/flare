defmodule Flare.Projects.ApiKey do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "api_keys" do
    field :prefix, :string
    field :hashed_secret, :string
    field :permissions, :map, default: %{}
    field :rotated_at, :utc_datetime_usec
    field :expires_at, :utc_datetime_usec
    belongs_to :organization, Flare.Accounts.Organization
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(k, attrs) do
    k
    |> cast(attrs, [:prefix, :hashed_secret, :permissions, :organization_id, :expires_at])
    |> validate_required([:prefix, :hashed_secret, :organization_id])
    |> unique_constraint(:prefix)
  end
end
