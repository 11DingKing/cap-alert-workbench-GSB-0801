defmodule CapAlertWorkbench.Alerts.Stream do
  @moduledoc "预警消息流（聚合根）。identifier 全局稳定唯一。"
  use Ecto.Schema

  alias CapAlertWorkbench.Cap.Lifecycle

  schema "alert_streams" do
    field :identifier, :string
    field :sender, :string
    field :state, Ecto.Enum, values: Lifecycle.stream_states(), default: :drafting

    has_many :versions, CapAlertWorkbench.Alerts.Version
    has_many :published_documents, CapAlertWorkbench.Alerts.PublishedDocument

    timestamps(type: :utc_datetime_usec)
  end
end
