defmodule CapAlertWorkbench.Alerts.ReviewDecision do
  @moduledoc "复核结论记录。pinned_lock_version 防止旧结论套用到新草稿。"
  use Ecto.Schema

  schema "review_decisions" do
    field :decision, Ecto.Enum, values: [:approved, :rejected]
    field :reviewer, :string
    field :note, :string
    field :pinned_lock_version, :integer

    belongs_to :version, CapAlertWorkbench.Alerts.Version

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
