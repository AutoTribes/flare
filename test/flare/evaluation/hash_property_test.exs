defmodule Flare.Evaluation.HashPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  alias Flare.Evaluation.Hash

  property "same input always yields same bucket" do
    check all(key <- string(:alphanumeric, min_length: 1)) do
      assert Hash.bucket("f", "s", key) == Hash.bucket("f", "s", key)
    end
  end

  test "distribution is roughly uniform across 100k keys" do
    counts =
      for i <- 1..100_000 do
        trunc(Hash.bucket("flag", "salt", "user-#{i}") / 10)
      end
      |> Enum.frequencies()

    Enum.each(0..9, fn d ->
      pct = Map.get(counts, d, 0) / 100_000 * 100
      assert pct > 8.0 and pct < 12.0, "decile #{d} had #{pct}%"
    end)
  end
end
