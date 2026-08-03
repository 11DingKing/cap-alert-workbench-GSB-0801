defmodule CapAlertWorkbench.Cap.Review do
  @moduledoc """
  A review decision bound to a specific draft revision. If the draft is edited
  after the review targets it, `decision_revision` will no longer match the
  alert's `draft_revision` and the decision is considered stale.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @decisions [:approved, :changes_requested, :rejected]

  schema "cap_alert_reviews" do
    field :decision, Ecto.Enum, values: @decisions
    field :decision_revision, :integer
    field :reviewer, :string
    field :comment, :string
    field :stale, :boolean, default: false

    belongs_to :alert, CapAlertWorkbench.Cap.Alert
    belongs_to :version, CapAlertWorkbench.Cap.Version

    timestamps(type: :utc_datetime)
  end

  def changeset(review, attrs) do
    review
    |> cast(attrs, [
      :alert_id,
      :version_id,
      :decision,
      :decision_revision,
      :reviewer,
      :comment,
      :stale
    ])
    |> validate_required([:alert_id, :decision, :decision_revision, :reviewer])
    |> validate_inclusion(:decision, @decisions)
    |> validate_number(:decision_revision, greater_than_or_equal_to: 1)
  end
end
