defmodule CapAlertWorkbench.Repo.Migrations.CreateCapAlerts do
  use Ecto.Migration

  def change do
    create table(:cap_alerts, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :identifier, :string, null: false
      add :sender, :string, null: false
      add :draft_lock_version, :integer, null: false, default: 1
      add :draft_revision, :integer, null: false, default: 1
      add :published_identifier, :string
      add :latest_published_version, :integer
      add :status, :string, null: false, default: "draft"
      add :draft_payload, :map, null: false
      add :last_activity_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:cap_alerts, [:identifier])
    create index(:cap_alerts, [:status])
    create index(:cap_alerts, [:last_activity_at])

    create constraint(:cap_alerts, :draft_lock_version_positive, check: "draft_lock_version >= 1")

    create constraint(:cap_alerts, :draft_revision_positive, check: "draft_revision >= 1")
  end
end
