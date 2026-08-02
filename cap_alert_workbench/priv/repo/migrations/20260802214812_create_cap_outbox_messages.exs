defmodule CapAlertWorkbench.Repo.Migrations.CreateCapOutboxMessages do
  use Ecto.Migration

  def change do
    create table(:cap_outbox_messages, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :alert_id, references(:cap_alerts, type: :binary_id, on_delete: :nilify_all)
      add :topic, :string, null: false
      add :payload, :map, null: false
      add :status, :string, null: false, default: "pending"
      add :attempts, :integer, null: false, default: 0
      add :last_error, :text
      add :available_at, :utc_datetime, null: false
      add :delivered_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:cap_outbox_messages, [:status, :available_at])
    create index(:cap_outbox_messages, [:alert_id])
  end
end
