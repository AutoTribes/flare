defmodule Flare.Evaluation.Decision do
  @moduledoc "The result of evaluating one flag."
  @enforce_keys [:reason]
  defstruct [:value, :variant, :enabled, :matched_rule_id, :reason, :bucket]

  @type reason ::
          :off
          | :prerequisite_failed
          | :target_match
          | :rule_match
          | :segment_match
          | :rollout
          | :fallthrough
          | :default
          | :flag_not_found

  @type t :: %__MODULE__{
          value: term(),
          variant: String.t() | nil,
          enabled: boolean() | nil,
          matched_rule_id: term(),
          reason: reason(),
          bucket: float() | nil
        }
end
