defmodule CapAlertWorkbench.Repo.Migrations.MigrateAlertVersionsToMultiInfo do
  use Ecto.Migration

  def up do
    alter table(:alert_versions) do
      add :infos, :jsonb, null: false, default: fragment("'[]'::jsonb")
    end

    execute(&migrate_flat_to_infos/0, &restore_flat_from_infos/0)

    alter table(:alert_versions) do
      remove :language
      remove :event
      remove :headline
      remove :description
      remove :instruction
      remove :urgency
      remove :severity
      remove :certainty
      remove :area_desc
      remove :geocodes
    end
  end

  def down do
    alter table(:alert_versions) do
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
    end

    execute(&restore_flat_from_infos/0, &migrate_flat_to_infos/0)

    alter table(:alert_versions) do
      remove :infos
    end
  end

  defp migrate_flat_to_infos do
    repo().query!(
      """
      UPDATE alert_versions
      SET infos = jsonb_build_array(
        jsonb_strip_nulls(
          jsonb_build_object(
            'language', language,
            'event', event,
            'urgency', urgency,
            'severity', severity,
            'certainty', certainty,
            'headline', headline,
            'description', description,
            'instruction', instruction,
            'area_desc', area_desc,
            'geocodes', geocodes,
            'extensions', '[]'::jsonb
          )
        )
      )
      """,
      []
    )
  end

  defp restore_flat_from_infos do
    repo().query!(
      """
      UPDATE alert_versions av
      SET
        language = info->>'language',
        event = info->>'event',
        urgency = info->>'urgency',
        severity = info->>'severity',
        certainty = info->>'certainty',
        headline = info->>'headline',
        description = info->>'description',
        instruction = info->>'instruction',
        area_desc = info->>'area_desc',
        geocodes = COALESCE(info->'geocodes', '[]'::jsonb)
      FROM (
        SELECT id, jsonb_array_elements(infos) AS info
        FROM alert_versions
      ) sub
      WHERE av.id = sub.id
      """,
      []
    )
  end
end
