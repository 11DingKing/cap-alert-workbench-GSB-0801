defmodule CapWorkbench.Repo.Migrations.CreateAuditEvents do
  use Ecto.Migration

  def change do
    create table(:audit_events, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :alert_message_id,
          references(:alert_messages, type: :binary_id, on_delete: :delete_all),
          null: false

      add :draft_version_id, :binary_id

      # Explicit action enum (e.g. :draft_created, :version_saved, :submitted,
      # :approved, :rejected, :published, :correction_created, :cancellation_created).
      add :action, :string, null: false

      add :actor, :string, null: false
      add :from_state, :string
      add :to_state, :string

      # Structured, immutable payload describing the transition.
      add :metadata, :map, null: false, default: %{}

      add :occurred_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:audit_events, [:alert_message_id])
    create index(:audit_events, [:action])
    create index(:audit_events, [:occurred_at])
  end
end
