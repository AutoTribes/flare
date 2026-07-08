defmodule Flare.Flags.FeatureFlag do
  use Ecto.Schema
  import Ecto.Changeset

  @kinds ~w(boolean multivariate json)
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "feature_flags" do
    field :key, :string
    field :kind, :string
    field :description, :string
    field :tags, {:array, :string}, default: []
    field :rollout_salt, :string
    field :archived_at, :utc_datetime_usec
    belongs_to :project, Flare.Projects.Project
    belongs_to :owner, Flare.Accounts.User
    has_many :variants, Flare.Flags.FeatureVariant
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(flag, attrs) do
    flag
    |> cast(attrs, [
      :key,
      :kind,
      :description,
      :tags,
      :project_id,
      :owner_id,
      :rollout_salt,
      :archived_at
    ])
    |> validate_required([:key, :kind, :project_id])
    |> validate_inclusion(:kind, @kinds)
    |> validate_format(:key, ~r/^[a-z0-9_.-]+$/)
    |> put_salt()
    |> unique_constraint([:project_id, :key])
  end

  defp put_salt(cs) do
    case get_field(cs, :rollout_salt) do
      nil ->
        put_change(
          cs,
          :rollout_salt,
          16 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
        )

      _ ->
        cs
    end
  end
end
