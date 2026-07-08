defmodule Flare.Evaluation.HashTest do
  use ExUnit.Case, async: true
  alias Flare.Evaluation.Hash

  test "canonical MurmurHash3 x86_32 vectors (cross-language contract)" do
    assert Hash.murmur3_32("") == 0
    assert Hash.murmur3_32("hello") == 613_153_351
  end

  test "bucket is stable and in range" do
    b1 = Hash.bucket("payment_v2", "salt123", "user-abc")
    b2 = Hash.bucket("payment_v2", "salt123", "user-abc")
    assert b1 == b2
    assert b1 >= 0.0 and b1 < 100.0
  end

  test "in_rollout? boundaries" do
    refute Hash.in_rollout?("f", "s", "k", 0)
    assert Hash.in_rollout?("f", "s", "k", 100)
  end

  test "hash conformance fixtures" do
    "test/fixtures/hash_conformance.json"
    |> File.read!()
    |> Jason.decode!()
    |> Enum.each(fn %{"input" => input, "hash" => expected} ->
      assert Flare.Evaluation.Hash.murmur3_32(input) == expected, "mismatch for #{inspect(input)}"
    end)
  end

  test "rollout conformance fixtures" do
    "test/fixtures/rollout_conformance.json"
    |> File.read!()
    |> Jason.decode!()
    |> Enum.each(fn f ->
      assert Flare.Evaluation.Hash.in_rollout?(
               f["flag_key"],
               f["salt"],
               f["bucketing_key"],
               f["percentage"]
             ) ==
               f["in_rollout"]
    end)
  end
end
