defmodule CapWorkbench.Repo.Migrations.CreateAlertMessages do
  use Ecto.Migration

  def change do
    create table(:alert_messages, primary_key: false) do
      add :id, :binary_id, primary_key: true

      # Stable CAP envelope identity. Never mutated once created.
      add :identifier, :string, null: false
      add :sender, :string, null: false
      add :sent_at, :utc_datetime_usec, null: false

      # CAP envelope enums, stored as strings but constrained by domain enums.
      add :status, :string, null: false
      add :msg_type, :string, null: false
      add :scope, :string, null: false

      # Editorial workflow state (distinct from CAP status).
      add :workflow_state, :string, null: false, default: "drafting"

      # References for update/cancel messages (stable pointer + CAP references text).
      add :references_message_id,
          references(:alert_messages, type: :binary_id, on_delete: :nilify_all)

      add :references_text, :text

      # Points at the immutable version that was published (if any).
      add :published_version_id, :binary_id

      # Optimistic lock guarding workflow transitions.
      add :lock_version, :integer, null: false, default: 1

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:alert_messages, [:identifier])
    create index(:alert_messages, [:references_message_id])
    create index(:alert_messages, [:workflow_state])
  end
end
