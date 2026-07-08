defmodule Flare.Targeting.Compiler do
  @moduledoc """
  Compiles a stored JSON rule into a nested tuple form with segments inlined.
  Compiled node shapes:
    {:and, [nodes]} | {:or, [nodes]} | {:cond, attr, operator, values} |
    :always_true | :always_false
  """

  @spec compile(map(), map()) :: term()
  def compile(rule, segments) when is_map(rule), do: do_compile(rule, segments)

  defp do_compile(%{"op" => "and", "conditions" => conds}, segs),
    do: {:and, Enum.map(conds, &do_compile(&1, segs))}

  defp do_compile(%{"op" => "or", "conditions" => conds}, segs),
    do: {:or, Enum.map(conds, &do_compile(&1, segs))}

  defp do_compile(%{"segment" => key}, segs) do
    case Map.get(segs, key) do
      nil -> :always_false
      rule -> do_compile(rule, segs)
    end
  end

  defp do_compile(%{"attr" => attr, "operator" => op, "values" => values}, _segs),
    do: {:cond, attr, op, values}

  defp do_compile(empty, _segs) when empty == %{}, do: :always_true
  defp do_compile(_other, _segs), do: :always_false
end
