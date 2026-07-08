defmodule Flare.Evaluation.Ruleset do
  @moduledoc """
  Compiled, evaluable snapshot of all flags in one environment. Pure data.
  `build/3` turns plain flag maps + segment map into compiled form (rules
  compiled, segments inlined). This is the shape shipped to SDKs.
  """
  alias Flare.Targeting.Compiler

  defstruct version: 0, flags: %{}

  @type t :: %__MODULE__{version: integer(), flags: map()}

  @spec build([map()], map(), integer()) :: %__MODULE__{}
  def build(flags, segments, version) do
    compiled =
      for f <- flags, into: %{} do
        {f.key,
         %{
           key: f.key,
           kind: f.kind,
           salt: f.salt,
           enabled: f.enabled,
           compiled_rules: compile_rules(Map.get(f, :rules, %{}), segments),
           rollout: Map.get(f, :rollout, %{}),
           default_variant: f.default_variant,
           off_variant: f.off_variant,
           variants: f.variants,
           targets: Map.get(f, :targets, %{}),
           bucket_by: Map.get(f, :bucket_by, "user_id")
         }}
      end

    %__MODULE__{version: version, flags: compiled}
  end

  @doc "Build a compiled Ruleset from a decoded JSON payload (string keys)."
  @spec from_payload(map()) :: %__MODULE__{}
  def from_payload(%{"version" => v, "flags" => flags, "segments" => segments}) do
    atom_flags =
      Enum.map(flags, fn f ->
        %{
          key: f["key"],
          kind: f["kind"],
          salt: f["salt"],
          enabled: f["enabled"],
          rules: f["rules"] || %{},
          rollout: f["rollout"] || %{},
          default_variant: f["default_variant"],
          off_variant: f["off_variant"],
          variants: f["variants"] || %{},
          targets: f["targets"] || %{},
          bucket_by: f["bucket_by"] || "user_id"
        }
      end)

    build(atom_flags, segments, v)
  end

  defp compile_rules(rules, segments) when is_map(rules) do
    case rules do
      %{"list" => list} when is_list(list) ->
        Enum.map(list, fn %{"id" => id, "rule" => r, "variant" => v} ->
          %{id: id, node: Compiler.compile(r, segments), variant: v}
        end)

      _ ->
        []
    end
  end
end
