defmodule Flare.Targeting.Operators do
  @moduledoc "Pure operator library. `apply/3` never raises; missing attr -> false."

  # This module deliberately names its public function `apply/3`. Exclude the
  # auto-imported Kernel.apply/3 to avoid any conflict warning under
  # --warnings-as-errors.
  import Kernel, except: [apply: 3]

  @spec apply(String.t(), term(), list()) :: boolean()
  def apply(_op, nil, _values), do: false

  def apply("equals", attr, values) do
    case coerce_str(attr) do
      :error -> false
      {:ok, s} -> s in coerced_values(values)
    end
  end

  def apply("not_equals", attr, values) do
    case coerce_str(attr) do
      :error -> false
      {:ok, s} -> s not in coerced_values(values)
    end
  end

  def apply("in", attr, values) do
    case coerce_str(attr) do
      :error -> false
      {:ok, s} -> s in coerced_values(values)
    end
  end

  def apply("contains", attr, [v | _]), do: string_op(attr, v, &String.contains?/2)
  def apply("starts_with", attr, [v | _]), do: string_op(attr, v, &String.starts_with?/2)
  def apply("ends_with", attr, [v | _]), do: string_op(attr, v, &String.ends_with?/2)
  def apply("gt", attr, [v | _]), do: compare_num(attr, v) == :gt
  def apply("lt", attr, [v | _]), do: compare_num(attr, v) == :lt
  def apply("gte", attr, [v | _]), do: compare_num(attr, v) in [:gt, :eq]
  def apply("lte", attr, [v | _]), do: compare_num(attr, v) in [:lt, :eq]
  def apply("regex", attr, [v | _]), do: string_op(attr, v, &regex_match/2)
  def apply("semver_eq", attr, [v | _]), do: compare_semver(attr, v) == :eq
  def apply("semver_gt", attr, [v | _]), do: compare_semver(attr, v) == :gt
  def apply("semver_lt", attr, [v | _]), do: compare_semver(attr, v) == :lt
  def apply("semver_gte", attr, [v | _]), do: compare_semver(attr, v) in [:gt, :eq]
  def apply("semver_lte", attr, [v | _]), do: compare_semver(attr, v) in [:lt, :eq]
  def apply(_unknown, _attr, _values), do: false

  # -- string coercion (C1) ---------------------------------------------------

  @spec coerce_str(term()) :: {:ok, binary()} | :error
  def coerce_str(v) when is_binary(v), do: {:ok, v}
  def coerce_str(v) when is_integer(v), do: {:ok, Integer.to_string(v)}
  def coerce_str(v) when is_boolean(v), do: {:ok, to_string(v)}

  def coerce_str(v) when is_float(v) do
    if trunc(v) == v do
      {:ok, Integer.to_string(trunc(v))}
    else
      {:ok, Float.to_string(v)}
    end
  end

  def coerce_str(v) when is_atom(v) and not is_nil(v), do: {:ok, Atom.to_string(v)}
  def coerce_str(_), do: :error

  defp coerced_values(values) do
    values
    |> Enum.map(&coerce_str/1)
    |> Enum.filter(&match?({:ok, _}, &1))
    |> Enum.map(fn {:ok, s} -> s end)
  end

  defp string_op(attr, v, fun) do
    with {:ok, a} <- coerce_str(attr), {:ok, b} <- coerce_str(v) do
      fun.(a, b)
    else
      :error -> false
    end
  end

  # -- numeric coercion (C2), strict ------------------------------------------

  @spec coerce_num(term()) :: {:ok, number()} | :error
  def coerce_num(v) when is_number(v), do: {:ok, v}

  def coerce_num(v) when is_binary(v) do
    case Integer.parse(v) do
      {n, ""} ->
        {:ok, n}

      _ ->
        case Float.parse(v) do
          {f, ""} -> {:ok, f}
          _ -> :error
        end
    end
  end

  def coerce_num(_), do: :error

  defp compare_num(a, b) do
    with {:ok, an} <- coerce_num(a), {:ok, bn} <- coerce_num(b) do
      cond do
        an > bn -> :gt
        an < bn -> :lt
        true -> :eq
      end
    else
      _ -> :error
    end
  end

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

  # -- semver padding + leading-v strip (M1) ----------------------------------

  defp parse_semver(v) do
    case coerce_str(v) do
      {:ok, s} ->
        s
        |> strip_leading_v()
        |> pad_semver()
        |> Version.parse()

      :error ->
        :error
    end
  end

  defp strip_leading_v(<<c, rest::binary>>) when c in [?v, ?V], do: rest
  defp strip_leading_v(s), do: s

  defp pad_semver(s) do
    case Enum.count(String.graphemes(s), &(&1 == ".")) do
      0 -> s <> ".0.0"
      1 -> s <> ".0"
      _ -> s
    end
  end
end
