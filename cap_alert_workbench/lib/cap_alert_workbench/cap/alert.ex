defmodule CapAlertWorkbench.Cap.Alert do
  @moduledoc """
  Aggregate root for a CAP alert thread. Holds the editable working draft and
  points at the latest published version (if any). All immutable history lives
  in `CapAlertWorkbench.Cap.Version`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "cap_alerts" do
    field :identifier, :string
    field :sender, :string
    field :draft_lock_version, :integer, default: 1
    field :draft_revision, :integer, default: 1
    field :published_identifier, :string
    field :latest_published_version, :integer

    field :status, Ecto.Enum,
      values: [:draft, :in_review, :approved, :rejected, :published, :canceled],
      default: :draft

    field :draft_payload, :map
    field :last_activity_at, :utc_datetime

    has_many :versions, CapAlertWorkbench.Cap.Version
    has_many :reviews, CapAlertWorkbench.Cap.Review
    has_many :audit_events, CapAlertWorkbench.Cap.AuditEvent

    timestamps(type: :utc_datetime)
  end

  def changeset(alert, attrs) do
    alert
    |> cast(attrs, [
      :identifier,
      :sender,
      :draft_lock_version,
      :draft_revision,
      :published_identifier,
      :latest_published_version,
      :status,
      :draft_payload,
      :last_activity_at
    ])
    |> validate_required([:identifier, :sender, :draft_lock_version, :draft_revision])
    |> validate_number(:draft_lock_version, greater_than_or_equal_to: 1)
    |> validate_number(:draft_revision, greater_than_or_equal_to: 1)
    |> unique_constraint(:identifier)
  end
end
