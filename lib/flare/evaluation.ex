defmodule Flare.Evaluation do
  @moduledoc """
  Public evaluation facade. `evaluate/3` is the hot path used by the dashboard
  simulator, the SDK reference implementation, and any server-side evaluation.
  Pure — no I/O.
  """
  alias Flare.Evaluation.{Ruleset, Evaluator, Decision, Context}

  @spec evaluate(Ruleset.t(), String.t(), Context.t()) :: Decision.t()
  def evaluate(%Ruleset{flags: flags}, flag_key, %Context{} = ctx) do
    flags |> Map.get(flag_key) |> Evaluator.evaluate(ctx)
  end
end
