defmodule Flare.Flags.FlagVersion do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "flag_versions" do
    field :version, :integer
    field :snapshot, :map
    field :diff, :map
    field :change_type, :string
    belongs_to :feature_flag, Flare.Flags.FeatureFlag
    belongs_to :environment, Flare.Projects.Environment
    belongs_to :changed_by, Flare.Accounts.User
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(v, attrs) do
    v
    |> cast(attrs, [
      :version,
      :snapshot,
      :diff,
      :change_type,
      :feature_flag_id,
      :environment_id,
      :changed_by_id
    ])
    |> validate_required([:version, :snapshot, :change_type, :feature_flag_id, :environment_id])
    |> unique_constraint([:environment_id, :version])
  end
end
