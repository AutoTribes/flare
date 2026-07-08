defmodule Flare.Evaluation.Hash do
  @moduledoc """
  MurmurHash3 x86 32-bit (via the `murmur` library) and deterministic rollout
  bucketing.

  This is the cross-language contract: every SDK MUST produce byte-identical
  results for the fixtures in test/fixtures/*.json. The hash is standard
  MurmurHash3_x86_32 with seed 0 (unsigned), matching Python mmh3, JS, and Dart.
  """

  @doc "MurmurHash3 x86_32 (seed 0) of a binary, as an unsigned 32-bit integer."
  @spec murmur3_32(binary()) :: non_neg_integer()
  def murmur3_32(data) when is_binary(data), do: Murmur.hash_x86_32(data)

  @doc """
  Deterministic rollout bucket in the range 0.0..99.999 for a
  (flag_key, salt, bucketing_key) triple. Same input -> same bucket forever.
  """
  @spec bucket(String.t(), String.t(), String.t()) :: float()
  def bucket(flag_key, salt, bucketing_key) do
    h = murmur3_32("#{flag_key}:#{salt}:#{bucketing_key}")
    rem(h, 100_000) / 1000.0
  end

  @doc "True if the bucketing key falls within the rollout percentage (0..100)."
  @spec in_rollout?(String.t(), String.t(), String.t(), number()) :: boolean()
  def in_rollout?(flag_key, salt, bucketing_key, percentage) do
    bucket(flag_key, salt, bucketing_key) < percentage
  end
end
