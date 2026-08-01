defmodule CapAlertWorkbench.Alerts.AuditEvent do
  @moduledoc "审计事件，与状态变更同事务写入。"
  use Ecto.Schema

  schema "audit_events" do
    field :event, Ecto.Enum,
      values: [
        :stream_created,
        :draft_updated,
        :submitted_for_review,
        :review_approved,
        :review_rejected,
        :published,
        :correction_started,
        :cancellation_started,
        :imported
      ]

    field :actor, :string
    field :details, :map

    belongs_to :stream, CapAlertWorkbench.Alerts.Stream
    belongs_to :version, CapAlertWorkbench.Alerts.Version

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
