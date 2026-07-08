defmodule Flare.Audit do
  @moduledoc "Audit context. Writes are enqueued via Oban so they never block the request."
  alias Flare.Audit.LogWorker

  @doc "Enqueue an audit log insert. attrs must be JSON-serializable."
  def log_async(attrs) when is_map(attrs) do
    attrs |> stringify() |> LogWorker.new() |> Oban.insert()
  end

  defp stringify(map), do: Map.new(map, fn {k, v} -> {to_string(k), v} end)
end
