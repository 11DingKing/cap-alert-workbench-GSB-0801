defmodule CapAlertWorkbench.CapAlert.NotificationOutbox do
  @moduledoc """
  Transactional outbox entry. Publishing a version atomically writes the outbox
  row in the same transaction as the state change; a separate publisher drains
  pending rows and broadcasts them.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias CapAlertWorkbench.CapAlert.Enums

  @primary_key {:id, :id, autogenerate: true}

  schema "notification_outbox" do
    field :alert_identifier, :string
    field :version_id, :integer
    field :event_type, :string
    field :payload, :map
    field :status, Ecto.Enum, values: Enums.outbox_statuses(), default: :pending
    field :attempts, :integer, default: 0
    field :last_error, :string
    field :published_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  def changeset(outbox, attrs) do
    outbox
    |> cast(attrs, [
      :alert_identifier,
      :version_id,
      :event_type,
      :payload,
      :status,
      :attempts,
      :last_error,
      :published_at
    ])
    |> validate_required([:alert_identifier, :event_type, :status])
  end
end
