defmodule Flare.Evaluation.EvaluatorTest do
  use ExUnit.Case, async: true
  alias Flare.Evaluation
  alias Flare.Evaluation.{Ruleset, Context}

  defp ruleset(flag_overrides) do
    base = %{
      key: "f",
      kind: "boolean",
      salt: "s",
      enabled: true,
      rules: %{},
      rollout: %{},
      default_variant: "on",
      off_variant: "off",
      variants: %{"on" => true, "off" => false},
      targets: %{},
      bucket_by: "user_id"
    }

    Ruleset.build([Map.merge(base, flag_overrides)], %{}, 1)
  end

  test "disabled flag returns off variant with reason :off" do
    rs = ruleset(%{enabled: false})
    d = Evaluation.evaluate(rs, "f", Context.new(%{user_id: "u"}))
    assert d.reason == :off
    assert d.value == false
    assert d.variant == "off"
  end

  test "enabled flag with no rules falls through to default" do
    rs = ruleset(%{})
    d = Evaluation.evaluate(rs, "f", Context.new(%{user_id: "u"}))
    assert d.reason == :fallthrough
    assert d.value == true
    assert d.variant == "on"
  end

  test "explicit target match wins" do
    rs = ruleset(%{targets: %{"off" => ["u-target"]}})
    d = Evaluation.evaluate(rs, "f", Context.new(%{user_id: "u-target"}))
    assert d.reason == :target_match
    assert d.variant == "off"
  end

  test "rule match returns rule's variant" do
    rules = %{
      "list" => [
        %{
          "id" => "r1",
          "rule" => %{"attr" => "country", "operator" => "equals", "values" => ["KE"]},
          "variant" => "off"
        }
      ]
    }

    rs = ruleset(%{rules: rules})
    d = Evaluation.evaluate(rs, "f", Context.new(%{user_id: "u", country: "KE"}))
    assert d.reason == :rule_match
    assert d.matched_rule_id == "r1"
    assert d.variant == "off"
  end

  test "rollout on fallthrough buckets deterministically" do
    rs = ruleset(%{rollout: %{"variant" => "on", "fallback" => "off", "percentage" => 0}})
    d = Evaluation.evaluate(rs, "f", Context.new(%{user_id: "u"}))
    assert d.reason == :rollout
    assert d.variant == "off"
    assert is_float(d.bucket)
  end

  test "missing flag returns :flag_not_found" do
    rs = ruleset(%{})
    d = Evaluation.evaluate(rs, "nope", Context.new(%{user_id: "u"}))
    assert d.reason == :flag_not_found
  end

  test "evaluation is fast (< 1ms average over 10k iterations)" do
    rules = %{
      "list" => [
        %{
          "id" => "r1",
          "rule" => %{"attr" => "country", "operator" => "in", "values" => ["KE", "UG", "TZ"]},
          "variant" => "off"
        }
      ]
    }

    rs = ruleset(%{rules: rules})
    ctx = Context.new(%{user_id: "u", country: "TZ"})

    {micros, _} =
      :timer.tc(fn ->
        for _ <- 1..10_000, do: Evaluation.evaluate(rs, "f", ctx)
      end)

    avg_us = micros / 10_000
    assert avg_us < 1000, "avg eval was #{avg_us}us"
  end
end
