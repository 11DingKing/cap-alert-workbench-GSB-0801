defmodule CapAlertWorkbench.Repo.Migrations.CreateCapAlertVersions do
  use Ecto.Migration

  def change do
    create table(:cap_alert_versions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :alert_id, references(:cap_alerts, type: :binary_id, on_delete: :restrict), null: false
      add :version_number, :integer, null: false
      add :status, :string, null: false
      add :kind, :string, null: false, default: "draft"
      add :payload, :map, null: false
      add :xml_snapshot, :text
      add :references, {:array, :string}, null: false, default: []
      add :superseded_by, :binary_id
      add :created_by, :string
      add :review_note, :string
      add :published_at, :utc_datetime
      add :revision_seed, :integer

      add :inserted_at, :utc_datetime, null: false
    end

    create unique_index(:cap_alert_versions, [:alert_id, :version_number])
    create index(:cap_alert_versions, [:alert_id, :status])
    create index(:cap_alert_versions, [:superseded_by])

    create constraint(:cap_alert_versions, :version_number_positive, check: "version_number >= 1")

    create constraint(:cap_alert_versions, :published_required_when_published,
             check: "status <> 'published' OR published_at IS NOT NULL"
           )
  end
end
