defmodule CapWorkbench.Cap.OutboxEntry do
  @moduledoc """
  Transactional outbox row for downstream dispatch of published alerts.

  A row is created in the same transaction as the publish/correction/cancel it
  represents. The `dedupe_key` unique index guarantees a given dispatch is only
  ever enqueued once, so a retried or duplicated publish cannot double-send.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias CapWorkbench.Cap.Enums

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "notification_outbox" do
    field :draft_version_id, :binary_id
    field :event_type, Ecto.Enum, values: Enums.outbox_events()
    field :status, Ecto.Enum, values: Enums.outbox_states(), default: :pending
    field :dedupe_key, :string
    field :payload_xml, :string
    field :attempts, :integer, default: 0
    field :last_error, :string
    field :delivered_at, :utc_datetime_usec

    belongs_to :alert_message, CapWorkbench.Cap.AlertMessage

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [
      :alert_message_id,
      :draft_version_id,
      :event_type,
      :status,
      :dedupe_key,
      :payload_xml,
      :attempts,
      :last_error,
      :delivered_at
    ])
    |> validate_required([
      :alert_message_id,
      :draft_version_id,
      :event_type,
      :dedupe_key,
      :payload_xml
    ])
    |> unique_constraint(:dedupe_key)
  end
end
