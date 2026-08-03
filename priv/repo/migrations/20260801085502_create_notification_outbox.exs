defmodule CapWorkbench.Repo.Migrations.CreateNotificationOutbox do
  use Ecto.Migration

  def change do
    create table(:notification_outbox, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :alert_message_id,
          references(:alert_messages, type: :binary_id, on_delete: :delete_all),
          null: false

      add :draft_version_id, :binary_id, null: false

      # Explicit event type enum (:published, :corrected, :cancelled).
      add :event_type, :string, null: false

      # Delivery lifecycle enum (:pending, :delivered, :failed).
      add :status, :string, null: false, default: "pending"

      # Idempotency guard: one outbox row per unique dispatch of a version.
      add :dedupe_key, :string, null: false

      # Serialized CAP XML payload captured at publish time (immutable snapshot).
      add :payload_xml, :text, null: false

      add :attempts, :integer, null: false, default: 0
      add :last_error, :text
      add :delivered_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:notification_outbox, [:dedupe_key])
    create index(:notification_outbox, [:status])
    create index(:notification_outbox, [:alert_message_id])
  end
end
