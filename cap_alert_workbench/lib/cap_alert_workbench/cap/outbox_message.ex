defmodule CapAlertWorkbench.Cap.OutboxMessage do
  @moduledoc """
  Transactional outbox message. Created inside the same database transaction
  as the domain state change so that page state, immutable versions, audit
  events and notifications always commit or fail together.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses [:pending, :delivered, :failed]

  schema "cap_outbox_messages" do
    field :topic, :string
    field :payload, :map
    field :status, Ecto.Enum, values: @statuses, default: :pending
    field :attempts, :integer, default: 0
    field :last_error, :string
    field :available_at, :utc_datetime
    field :delivered_at, :utc_datetime

    belongs_to :alert, CapAlertWorkbench.Cap.Alert

    timestamps(type: :utc_datetime)
  end

  def changeset(message, attrs) do
    message
    |> cast(attrs, [
      :alert_id,
      :topic,
      :payload,
      :status,
      :attempts,
      :last_error,
      :available_at,
      :delivered_at
    ])
    |> validate_required([:topic, :payload, :status, :available_at])
  end
end
