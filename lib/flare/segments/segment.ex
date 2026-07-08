defmodule Flare.Segments.Segment do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "segments" do
    field :key, :string
    field :name, :string
    field :rules, :map, default: %{}
    belongs_to :project, Flare.Projects.Project
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(s, attrs) do
    s
    |> cast(attrs, [:key, :name, :rules, :project_id])
    |> validate_required([:key, :name, :project_id])
    |> validate_format(:key, ~r/^[a-z0-9_-]+$/)
    |> unique_constraint([:project_id, :key])
  end
end
