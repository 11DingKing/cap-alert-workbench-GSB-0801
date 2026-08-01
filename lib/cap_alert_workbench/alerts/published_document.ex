defmodule CapAlertWorkbench.Alerts.PublishedDocument do
  @moduledoc "已发布 CAP 文档：不可变快照（含冻结 XML）。"
  use Ecto.Schema

  schema "published_documents" do
    field :identifier, :string
    field :msg_type, Ecto.Enum, values: [:alert, :update, :cancel]
    field :cap_xml, :string
    field :sent_at, :utc_datetime_usec

    belongs_to :stream, CapAlertWorkbench.Alerts.Stream
    belongs_to :version, CapAlertWorkbench.Alerts.Version

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
