defmodule Flare.Segments do
  @moduledoc "Segments context."
  import Ecto.Query
  alias Flare.Repo
  alias Flare.Segments.Segment

  def create_segment(attrs), do: %Segment{} |> Segment.changeset(attrs) |> Repo.insert()

  @doc "Returns %{segment_key => rules_json} for a project — used for inlining."
  def segment_map(project_id) do
    from(s in Segment, where: s.project_id == ^project_id, select: {s.key, s.rules})
    |> Repo.all()
    |> Map.new()
  end
end
