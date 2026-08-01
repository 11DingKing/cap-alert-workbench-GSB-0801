defmodule CapAlertWorkbench.Alerts.OutboxEvent do
  @moduledoc "通知 outbox，与发布同事务写入。"
  use Ecto.Schema

  schema "outbox_events" do
    field :type, Ecto.Enum, values: [:alert_published, :alert_corrected, :alert_cancelled]
    field :payload, :map
    field :status, Ecto.Enum, values: [:pending, :delivered], default: :pending

    belongs_to :stream, CapAlertWorkbench.Alerts.Stream
    belongs_to :version, CapAlertWorkbench.Alerts.Version

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
