defmodule Flare.Targeting.Rule do
  @moduledoc "Evaluates a compiled rule node against a flat attribute map."
  alias Flare.Targeting.Operators

  @spec matches?(term(), map()) :: boolean()
  def matches?(:always_true, _ctx), do: true
  def matches?(:always_false, _ctx), do: false
  def matches?({:and, nodes}, ctx), do: Enum.all?(nodes, &matches?(&1, ctx))
  def matches?({:or, nodes}, ctx), do: Enum.any?(nodes, &matches?(&1, ctx))

  def matches?({:cond, attr, op, values}, ctx),
    do: Operators.apply(op, Map.get(ctx, attr), values)
end
