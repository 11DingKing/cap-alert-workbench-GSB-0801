defmodule CapWorkbench.Repo.Migrations.CreateDraftVersions do
  use Ecto.Migration

  def change do
    create table(:draft_versions, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :alert_message_id,
          references(:alert_messages, type: :binary_id, on_delete: :delete_all),
          null: false

      # Monotonic version number per alert message.
      add :version_number, :integer, null: false

      # Full immutable content snapshot for this version.
      add :headline, :string, null: false
      add :description, :text, null: false
      add :instruction, :text
      add :event, :string, null: false
      add :category, :string, null: false
      add :urgency, :string, null: false
      add :severity, :string, null: false
      add :certainty, :string, null: false
      add :language, :string, null: false, default: "zh-CN"
      add :effective_at, :utc_datetime_usec
      add :onset_at, :utc_datetime_usec
      add :expires_at, :utc_datetime_usec

      # Area geocodes (SAME/adcode style), stored as a string array.
      add :area_description, :string, null: false
      add :geocodes, {:array, :string}, null: false, default: []

      # Unknown/forward-compatible CAP extension fields captured on import,
      # preserved for round-trip export. Stored as structured JSON, never concatenated.
      add :extensions, :map, null: false, default: %{}

      # Review lifecycle for THIS specific version.
      add :review_state, :string, null: false, default: "pending"
      add :reviewed_by, :string
      add :reviewed_at, :utc_datetime_usec
      add :review_comment, :text

      # Whether this immutable version was published.
      add :published, :boolean, null: false, default: false
      add :published_at, :utc_datetime_usec

      # Who authored the snapshot.
      add :created_by, :string, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:draft_versions, [:alert_message_id, :version_number])
    create index(:draft_versions, [:alert_message_id])
    create index(:draft_versions, [:review_state])
  end
end
