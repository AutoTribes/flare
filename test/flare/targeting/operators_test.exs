defmodule Flare.Targeting.OperatorsTest do
  use ExUnit.Case, async: true
  alias Flare.Targeting.Operators, as: Op

  test "equals / not_equals" do
    assert Op.apply("equals", "KE", ["KE"])
    refute Op.apply("equals", "UG", ["KE"])
    assert Op.apply("not_equals", "UG", ["KE"])
  end

  test "string ops" do
    assert Op.apply("contains", "hello world", ["lo w"])
    assert Op.apply("starts_with", "flare", ["fla"])
    assert Op.apply("ends_with", "flare", ["are"])
  end

  test "numeric ops coerce" do
    assert Op.apply("gt", 10, [5])
    assert Op.apply("gte", 5, [5])
    assert Op.apply("lt", "3", ["4"])
  end

  test "in list" do
    assert Op.apply("in", "b", ["a", "b", "c"])
    refute Op.apply("in", "z", ["a", "b"])
  end

  test "regex" do
    assert Op.apply("regex", "abc123", ["^[a-z]+[0-9]+$"])
    refute Op.apply("regex", "ABC", ["^[a-z]+$"])
  end

  test "semver" do
    assert Op.apply("semver_gte", "5.2.1", ["5.2.0"])
    refute Op.apply("semver_lt", "5.2.1", ["5.2.0"])
  end

  test "missing / nil attribute is always false, never crashes" do
    refute Op.apply("equals", nil, ["KE"])
    refute Op.apply("gt", nil, [5])
    refute Op.apply("regex", nil, ["x"])
  end

  test "unknown operator is false, never crashes" do
    refute Op.apply("no_such_op", "x", ["x"])
  end
end
