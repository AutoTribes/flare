defmodule Flare.Evaluation.Context do
  @moduledoc "Evaluation context. Flattens known attrs + custom into one string-keyed map."
  defstruct attrs: %{}, bucketing_keys: %{}

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

    %__MODULE__{attrs: Map.merge(custom, known), bucketing_keys: known}
  end

  @spec bucketing_key(%__MODULE__{}, String.t()) :: String.t()
  def bucketing_key(%__MODULE__{attrs: attrs}, by), do: to_string(Map.get(attrs, by, ""))
end
