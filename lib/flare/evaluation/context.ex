defmodule Flare.Evaluation.Context do
  @moduledoc """
  Evaluation context. Flattens known attrs + custom into one string-keyed map.

  Bucketing keys should be strings or integers; canonical stringification:
  integers render without a decimal so all SDKs agree. (Full float parity is
  out of scope — document it.)
  """
  defstruct attrs: %{}

  @type t :: %__MODULE__{attrs: map()}

  @known ~w(user_id email country city role app_version device operating_system organization)a

  @spec new(map()) :: %__MODULE__{}
  def new(input) when is_map(input) do
    known =
      @known
      |> Enum.reduce(%{}, fn k, acc ->
        case Map.get(input, k) || Map.get(input, to_string(k)) do
          nil -> acc
          v -> Map.put(acc, to_string(k), v)
        end
      end)

    custom = Map.get(input, :custom) || Map.get(input, "custom") || %{}
    custom = for {k, v} <- custom, into: %{}, do: {to_string(k), v}

    %__MODULE__{attrs: Map.merge(custom, known)}
  end

  @spec bucketing_key(%__MODULE__{}, String.t()) :: String.t()
  def bucketing_key(%__MODULE__{attrs: attrs}, by) do
    attrs |> Map.get(by, "") |> canonical_str()
  end

  defp canonical_str(v) when is_integer(v), do: Integer.to_string(v)
  defp canonical_str(v) when is_binary(v), do: v

  defp canonical_str(v) when is_float(v) do
    if trunc(v) == v, do: Integer.to_string(trunc(v)), else: to_string(v)
  end

  defp canonical_str(v), do: to_string(v)
end
