defmodule Flare.Evaluation.RulesetTest do
  use ExUnit.Case, async: true
  alias Flare.Evaluation.{Ruleset, Context}

  test "builds a compiled ruleset from plain maps and flattens context" do
    flags = [
      %{
        key: "payment_v2",
        kind: "boolean",
        salt: "s1",
        enabled: true,
        rules: %{},
        rollout: %{},
        default_variant: "true",
        off_variant: "false",
        variants: %{"true" => true, "false" => false},
        targets: %{},
        bucket_by: "user_id"
      }
    ]

    rs = Ruleset.build(flags, %{}, 7)
    assert rs.version == 7
    assert Map.has_key?(rs.flags, "payment_v2")

    ctx = Context.new(%{user_id: "u1", country: "KE", custom: %{"tier" => "gold"}})
    assert ctx.attrs["user_id"] == "u1"
    assert ctx.attrs["country"] == "KE"
    assert ctx.attrs["tier"] == "gold"
  end

  test "compiles a flag's rule list with segments inlined" do
    flags = [
      %{
        key: "f",
        kind: "boolean",
        salt: "s",
        enabled: true,
        rules: %{"list" => [%{"id" => "r1", "rule" => %{"segment" => "beta"}, "variant" => "on"}]},
        rollout: %{},
        default_variant: "off",
        off_variant: "off",
        variants: %{"on" => true, "off" => false},
        targets: %{},
        bucket_by: "user_id"
      }
    ]

    segments = %{
      "beta" => %{
        "op" => "and",
        "conditions" => [%{"attr" => "role", "operator" => "equals", "values" => ["driver"]}]
      }
    }

    rs = Ruleset.build(flags, segments, 1)
    [rule] = rs.flags["f"].compiled_rules
    assert rule.id == "r1"
    assert rule.variant == "on"
    # the compiled node should match a driver
    assert Flare.Targeting.Rule.matches?(rule.node, %{"role" => "driver"})
    refute Flare.Targeting.Rule.matches?(rule.node, %{"role" => "rider"})
  end
end
