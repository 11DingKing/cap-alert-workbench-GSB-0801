defmodule CapAlertWorkbench.CapAlert.AuditEvent do
  @moduledoc "An immutable audit record for every state/content change."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :id, autogenerate: true}

  schema "audit_events" do
    field :alert_identifier, :string
    field :version_id, :integer
    field :actor, :string
    field :action, :string
    field :details, :map

    field :inserted_at, :utc_datetime
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [:alert_identifier, :version_id, :actor, :action, :details, :inserted_at])
    |> validate_required([:alert_identifier, :actor, :action, :inserted_at])
  end
end
