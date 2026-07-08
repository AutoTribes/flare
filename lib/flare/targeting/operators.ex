defmodule Flare.Targeting.Operators do
  @moduledoc "Pure operator library. `apply/3` never raises; missing attr -> false."

  # This module deliberately names its public function `apply/3`. Exclude the
  # auto-imported Kernel.apply/3 to avoid any conflict warning under
  # --warnings-as-errors.
  import Kernel, except: [apply: 3]

  @spec apply(String.t(), term(), list()) :: boolean()
  def apply(_op, nil, _values), do: false

  def apply("equals", attr, values), do: to_s(attr) in Enum.map(values, &to_s/1)
  def apply("not_equals", attr, values), do: to_s(attr) not in Enum.map(values, &to_s/1)
  def apply("in", attr, values), do: to_s(attr) in Enum.map(values, &to_s/1)
  def apply("contains", attr, [v | _]), do: String.contains?(to_s(attr), to_s(v))
  def apply("starts_with", attr, [v | _]), do: String.starts_with?(to_s(attr), to_s(v))
  def apply("ends_with", attr, [v | _]), do: String.ends_with?(to_s(attr), to_s(v))
  def apply("gt", attr, [v | _]), do: compare_num(attr, v) == :gt
  def apply("lt", attr, [v | _]), do: compare_num(attr, v) == :lt
  def apply("gte", attr, [v | _]), do: compare_num(attr, v) in [:gt, :eq]
  def apply("lte", attr, [v | _]), do: compare_num(attr, v) in [:lt, :eq]
  def apply("regex", attr, [v | _]), do: regex_match(to_s(attr), to_s(v))
  def apply("semver_eq", attr, [v | _]), do: compare_semver(attr, v) == :eq
  def apply("semver_gt", attr, [v | _]), do: compare_semver(attr, v) == :gt
  def apply("semver_lt", attr, [v | _]), do: compare_semver(attr, v) == :lt
  def apply("semver_gte", attr, [v | _]), do: compare_semver(attr, v) in [:gt, :eq]
  def apply("semver_lte", attr, [v | _]), do: compare_semver(attr, v) in [:lt, :eq]
  def apply(_unknown, _attr, _values), do: false

  defp to_s(v) when is_binary(v), do: v
  defp to_s(v), do: to_string(v)

  defp compare_num(a, b) do
    with {af, _} <- to_float(a), {bf, _} <- to_float(b) do
      cond do
        af > bf -> :gt
        af < bf -> :lt
        true -> :eq
      end
    else
      _ -> :error
    end
  end

  defp to_float(v) when is_number(v), do: {v / 1, ""}
  defp to_float(v) when is_binary(v), do: Float.parse(v)
  defp to_float(_), do: :error

  defp regex_match(str, pattern) do
    case Regex.compile(pattern) do
      {:ok, re} -> Regex.match?(re, str)
      _ -> false
    end
  end

  defp compare_semver(a, b) do
    with {:ok, va} <- parse_semver(a), {:ok, vb} <- parse_semver(b) do
      Version.compare(va, vb)
    else
      _ -> :error
    end
  end

  defp parse_semver(v) do
    s = to_s(v)

    case Version.parse(s) do
      {:ok, _} = ok -> ok
      :error -> Version.parse(s <> ".0")
    end
  end
end
