defmodule CapAlertWorkbench.Repo.Migrations.CreateCapAuditEvents do
  use Ecto.Migration

  def change do
    create table(:cap_audit_events, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :alert_id, references(:cap_alerts, type: :binary_id, on_delete: :nilify_all)
      add :version_id, references(:cap_alert_versions, type: :binary_id, on_delete: :nilify_all)
      add :action, :string, null: false
      add :actor, :string
      add :summary, :text
      add :metadata, :map
      add :occurred_at, :utc_datetime, null: false

      add :inserted_at, :utc_datetime, null: false
    end

    create index(:cap_audit_events, [:alert_id, :occurred_at])
    create index(:cap_audit_events, [:action])
  end
end
