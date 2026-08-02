defmodule CapAlertWorkbench.Repo.Migrations.CreateCapAlertReviews do
  use Ecto.Migration

  def change do
    create table(:cap_alert_reviews, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :alert_id, references(:cap_alerts, type: :binary_id, on_delete: :restrict), null: false
      add :version_id, references(:cap_alert_versions, type: :binary_id, on_delete: :nilify_all)
      add :decision, :string, null: false
      add :decision_revision, :integer, null: false
      add :reviewer, :string, null: false
      add :comment, :text
      add :stale, :boolean, null: false, default: false

      timestamps(type: :utc_datetime)
    end

    create index(:cap_alert_reviews, [:alert_id, :inserted_at])
    create index(:cap_alert_reviews, [:alert_id, :stale])

    create constraint(:cap_alert_reviews, :decision_revision_positive,
             check: "decision_revision >= 1"
           )
  end
end
