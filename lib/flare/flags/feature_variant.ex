defmodule Flare.Flags.FeatureVariant do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "feature_variants" do
    field :key, :string
    field :name, :string
    field :value, :map
    belongs_to :feature_flag, Flare.Flags.FeatureFlag
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(v, attrs) do
    v
    |> cast(attrs, [:key, :name, :value, :feature_flag_id])
    |> validate_required([:key, :value, :feature_flag_id])
    |> unique_constraint([:feature_flag_id, :key])
  end
end
