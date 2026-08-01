defmodule CapAlertWorkbench.Repo.Migrations.CreateCapAlertTables do
  use Ecto.Migration

  def change do
    create table(:alerts, primary_key: false) do
      add :identifier, :string, primary_key: true
      add :sender, :string, null: false
      add :latest_version_id, :bigint
      add :published_version_id, :bigint
      add :state, :string, null: false, default: "active"

      timestamps(type: :utc_datetime)
    end

    create table(:alert_versions) do
      add :alert_identifier,
          references(:alerts, column: :identifier, type: :string, on_delete: :restrict),
          null: false

      add :version_number, :integer, null: false
      add :lock_version, :integer, null: false, default: 1

      add :sender, :string
      add :sent, :utc_datetime
      add :status, :string, null: false
      add :msg_type, :string, null: false
      add :scope, :string, null: false
      add :language, :string

      add :event, :string
      add :headline, :string
      add :description, :text
      add :instruction, :text

      add :urgency, :string
      add :severity, :string
      add :certainty, :string

      add :area_desc, :string
      add :geocodes, :jsonb, null: false, default: fragment("'[]'::jsonb")

      add :references, :text
      add :extensions, :jsonb, null: false, default: fragment("'[]'::jsonb")

      add :workflow_state, :string, null: false
      add :review_comment, :text
      add :reviewed_by, :string
      add :reviewed_at, :utc_datetime
      add :published_at, :utc_datetime

      add :based_on_version_id,
          references(:alert_versions, on_delete: :nilify_all)

      add :xml_payload, :text

      timestamps(type: :utc_datetime)
    end

    create unique_index(:alert_versions, [:alert_identifier, :version_number])
    create index(:alert_versions, [:alert_identifier, :workflow_state])
    create index(:alert_versions, [:workflow_state])

    create table(:audit_events) do
      add :alert_identifier,
          references(:alerts, column: :identifier, type: :string, on_delete: :delete_all),
          null: false

      add :version_id, references(:alert_versions, on_delete: :delete_all)
      add :actor, :string, null: false
      add :action, :string, null: false
      add :details, :jsonb, null: false, default: fragment("'{}'::jsonb")

      add :inserted_at, :utc_datetime, null: false
    end

    create index(:audit_events, [:alert_identifier, :inserted_at])

    create table(:notification_outbox) do
      add :alert_identifier,
          references(:alerts, column: :identifier, type: :string, on_delete: :delete_all),
          null: false

      add :version_id, references(:alert_versions, on_delete: :delete_all)
      add :event_type, :string, null: false
      add :payload, :jsonb, null: false, default: fragment("'{}'::jsonb")
      add :status, :string, null: false, default: "pending"
      add :attempts, :integer, null: false, default: 0
      add :last_error, :text
      add :published_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:notification_outbox, [:status, :inserted_at])
  end
end
