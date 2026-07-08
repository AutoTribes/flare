defmodule Flare.Evaluation.Evaluator do
  @moduledoc "Pure evaluation. No I/O. First-match-wins."
  alias Flare.Evaluation.{Context, Decision, Hash}
  alias Flare.Targeting.Rule

  @spec evaluate(map() | nil, Context.t()) :: Decision.t()
  def evaluate(nil, _ctx), do: %Decision{reason: :flag_not_found}

  def evaluate(%{enabled: false} = flag, _ctx) do
    variant(flag, flag.off_variant, :off, nil, nil)
  end

  def evaluate(flag, ctx) do
    cond do
      target = target_variant(flag, ctx) ->
        variant(flag, target, :target_match, nil, nil)

      match = rule_match(flag, ctx) ->
        variant(flag, match.variant, :rule_match, match.id, nil)

      true ->
        fallthrough(flag, ctx)
    end
  end

  defp target_variant(%{targets: targets}, ctx) do
    uid = ctx.attrs |> Map.get("user_id") |> to_string_or_nil()

    targets
    |> Enum.sort_by(fn {vk, _ids} -> vk end)
    |> Enum.find_value(fn {vk, ids} ->
      if uid && uid in Enum.map(ids, &to_string/1), do: vk, else: nil
    end)
  end

  defp to_string_or_nil(nil), do: nil
  defp to_string_or_nil(v), do: to_string(v)

  defp rule_match(%{compiled_rules: rules}, ctx) do
    Enum.find(rules, fn r -> Rule.matches?(r.node, ctx.attrs) end)
  end

  defp fallthrough(%{rollout: rollout} = flag, ctx) when map_size(rollout) > 0 do
    key = Context.bucketing_key(ctx, flag.bucket_by)
    bucket = Hash.bucket(flag.key, flag.salt, key)
    pct = rollout["percentage"] || 0

    chosen =
      if bucket < pct,
        do: rollout["variant"] || flag.default_variant,
        else: rollout["fallback"] || flag.off_variant

    variant(flag, chosen, :rollout, nil, bucket)
  end

  defp fallthrough(flag, _ctx) do
    variant(flag, flag.default_variant, :fallthrough, nil, nil)
  end

  defp variant(flag, variant_key, reason, rule_id, bucket) do
    value = Map.get(flag.variants, variant_key)

    %Decision{
      value: value,
      variant: variant_key,
      enabled: value == true,
      matched_rule_id: rule_id,
      reason: reason,
      bucket: bucket
    }
  end
end
