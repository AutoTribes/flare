defmodule Flare.Projects.Environment do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "environments" do
    field :name, :string
    field :key, :string
    field :ruleset_version, :integer, default: 0
    belongs_to :project, Flare.Projects.Project
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(env, attrs) do
    env
    |> cast(attrs, [:name, :key, :project_id])
    |> validate_required([:name, :key, :project_id])
    |> validate_format(:key, ~r/^[a-z0-9_-]+$/)
    |> unique_constraint([:project_id, :key])
  end
end
