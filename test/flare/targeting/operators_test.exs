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

  test "map/array/tuple attribute never crashes -> false (C1)" do
    assert Op.apply("equals", %{"a" => 1}, ["x"]) == false
    assert Op.apply("contains", ["a", "b"], ["a"]) == false
    assert Op.apply("regex", %{"x" => 1}, ["."]) == false
    assert Op.apply("semver_gt", %{}, ["1.0.0"]) == false
    assert Op.apply("in", %{"a" => 1}, [1, 2]) == false
  end

  test "strict numeric parsing rejects trailing garbage and whitespace (C2)" do
    refute Op.apply("gt", "5abc", [3])
    refute Op.apply("gt", "0x10", [1])
    refute Op.apply("lt", " 3", [4])
    refute Op.apply("gt", "", [0])
    assert Op.apply("gt", "5", [3])
    assert Op.apply("gte", "5.0", [5])
  end

  test "equality coerces integers/booleans canonically" do
    assert Op.apply("in", 5, [5, 6])
    assert Op.apply("equals", true, ["true"])
    assert Op.apply("equals", 5, ["5"])
  end

  test "semver pads and strips leading v (M1)" do
    assert Op.apply("semver_gte", "5", ["4.0.0"])
    assert Op.apply("semver_eq", "5.2", ["5.2.0"])
    assert Op.apply("semver_eq", "v5.2.0", ["5.2.0"])
  end
end
