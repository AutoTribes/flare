defmodule Flare.Audit.AuditLog do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "audit_logs" do
    field :action, :string
    field :entity_type, :string
    field :entity_id, :binary_id
    field :before, :map
    field :after, :map
    field :metadata, :map, default: %{}
    belongs_to :organization, Flare.Accounts.Organization
    belongs_to :actor, Flare.Accounts.User
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(l, attrs) do
    l
    |> cast(attrs, [
      :action,
      :entity_type,
      :entity_id,
      :before,
      :after,
      :metadata,
      :organization_id,
      :actor_id
    ])
    |> validate_required([:action, :entity_type, :organization_id])
  end
end
