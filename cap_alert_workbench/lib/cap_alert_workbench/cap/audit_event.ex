defmodule CapAlertWorkbench.Cap.AuditEvent do
  @moduledoc """
  Append-only audit log entry. Rows are never updated or deleted.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "cap_audit_events" do
    field :action, :string
    field :actor, :string
    field :summary, :string
    field :metadata, :map
    field :occurred_at, :utc_datetime

    belongs_to :alert, CapAlertWorkbench.Cap.Alert
    belongs_to :version, CapAlertWorkbench.Cap.Version

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [
      :alert_id,
      :version_id,
      :action,
      :actor,
      :summary,
      :metadata,
      :occurred_at
    ])
    |> validate_required([:action, :occurred_at])
  end
end
