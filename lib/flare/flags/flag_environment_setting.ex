defmodule Flare.Flags.FlagEnvironmentSetting do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "flag_environment_settings" do
    field :enabled, :boolean, default: false
    field :rules, :map, default: %{}
    field :rollout, :map, default: %{}
    field :default_variant_key, :string
    field :off_variant_key, :string
    belongs_to :feature_flag, Flare.Flags.FeatureFlag
    belongs_to :environment, Flare.Projects.Environment
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(s, attrs) do
    s
    |> cast(attrs, [
      :enabled,
      :rules,
      :rollout,
      :default_variant_key,
      :off_variant_key,
      :feature_flag_id,
      :environment_id
    ])
    |> validate_required([:feature_flag_id, :environment_id])
    |> unique_constraint([:feature_flag_id, :environment_id])
  end
end
