defmodule CapWorkbench.Repo.Migrations.RestructureDraftVersionsMultiInfo do
  use Ecto.Migration

  @moduledoc """
  Moves per-info content out of flat columns on `draft_versions` and into an
  embedded `infos` JSONB array, so a version can carry multiple CAP `<info>`
  blocks (e.g. the same event at different severities per region).

  Alert-level `extensions` remains on the row; per-info extensions live inside
  each embedded block.
  """

  def up do
    alter table(:draft_versions) do
      add :infos, :map, null: false, default: fragment("'[]'::jsonb")
    end

    # Drop the now-embedded per-info content columns.
    alter table(:draft_versions) do
      remove :headline
      remove :description
      remove :instruction
      remove :event
      remove :category
      remove :urgency
      remove :severity
      remove :certainty
      remove :language
      remove :effective_at
      remove :onset_at
      remove :expires_at
      remove :area_description
      remove :geocodes
    end
  end

  def down do
    alter table(:draft_versions) do
      remove :infos

      add :headline, :string
      add :description, :text
      add :instruction, :text
      add :event, :string
      add :category, :string
      add :urgency, :string
      add :severity, :string
      add :certainty, :string
      add :language, :string, default: "zh-CN"
      add :effective_at, :utc_datetime_usec
      add :onset_at, :utc_datetime_usec
      add :expires_at, :utc_datetime_usec
      add :area_description, :string
      add :geocodes, {:array, :string}, default: []
    end
  end
end
