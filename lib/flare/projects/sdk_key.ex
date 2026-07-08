defmodule Flare.Projects.SdkKey do
  use Ecto.Schema
  import Ecto.Changeset

  @kinds ~w(server client mobile)
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "sdk_keys" do
    field :kind, :string
    field :prefix, :string
    field :hashed_secret, :string
    field :last_used_at, :utc_datetime_usec
    field :rotated_at, :utc_datetime_usec
    field :expires_at, :utc_datetime_usec
    belongs_to :environment, Flare.Projects.Environment
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(k, attrs) do
    k
    |> cast(attrs, [:kind, :prefix, :hashed_secret, :environment_id, :expires_at])
    |> validate_required([:kind, :prefix, :hashed_secret, :environment_id])
    |> validate_inclusion(:kind, @kinds)
    |> unique_constraint(:prefix)
  end
end
