defmodule CapWorkbench.Cap.AuditEvent do
  @moduledoc """
  Append-only audit trail. One row per meaningful workflow transition. Rows are
  never updated or deleted; they are written inside the same transaction as the
  change they describe so the trail can never drift from state.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias CapWorkbench.Cap.Enums

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "audit_events" do
    field :draft_version_id, :binary_id
    field :action, Ecto.Enum, values: Enums.audit_actions()
    field :actor, :string
    field :from_state, :string
    field :to_state, :string
    field :metadata, :map, default: %{}
    field :occurred_at, :utc_datetime_usec

    belongs_to :alert_message, CapWorkbench.Cap.AlertMessage

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [
      :alert_message_id,
      :draft_version_id,
      :action,
      :actor,
      :from_state,
      :to_state,
      :metadata,
      :occurred_at
    ])
    |> validate_required([:alert_message_id, :action, :actor, :occurred_at])
  end
end
