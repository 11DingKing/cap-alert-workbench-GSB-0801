defmodule CapAlertWorkbench.Cap.Version do
  @moduledoc """
  Immutable snapshot of a CAP alert at a point in its lifecycle. Once a row is
  persisted it is never updated. Corrections and cancellations create new rows
  and supersede older ones.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses [:draft, :in_review, :approved, :rejected, :published, :superseded, :canceled]
  @kinds [:draft, :correction, :cancellation]

  schema "cap_alert_versions" do
    field :version_number, :integer
    field :status, Ecto.Enum, values: @statuses, default: :draft
    field :kind, Ecto.Enum, values: @kinds, default: :draft
    field :payload, :map
    field :xml_snapshot, :string
    field :references, {:array, :string}, default: []
    field :superseded_by, :binary_id
    field :created_by, :string
    field :review_note, :string
    field :published_at, :utc_datetime
    field :revision_seed, :integer

    belongs_to :alert, CapAlertWorkbench.Cap.Alert

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def changeset(version, attrs) do
    version
    |> cast(attrs, [
      :alert_id,
      :version_number,
      :status,
      :kind,
      :payload,
      :xml_snapshot,
      :references,
      :superseded_by,
      :created_by,
      :review_note,
      :published_at,
      :revision_seed
    ])
    |> validate_required([:alert_id, :version_number, :status, :payload, :kind])
    |> validate_number(:version_number, greater_than_or_equal_to: 1)
    |> unique_constraint([:alert_id, :version_number])
    |> check_constraint(:published_at,
      name: :published_required_when_published,
      message: "must be set when status is published"
    )
    |> protect_immutable()
  end

  # Once a version is published/superseded/canceled its content and status are
  # frozen. The only permitted mutation after publication is the supersede
  # transition performed by the dedicated service transaction, which changes
  # status from :published to :superseded and sets superseded_by at the exact
  # moment a new follow-up version is inserted.
  defp protect_immutable(changeset) do
    current_status = get_field(changeset, :status)
    persisted_status = changeset.data.status
    persisted? = changeset.data.id != nil
    changes = changeset.changes

    cond do
      not persisted? ->
        changeset

      # Allow the published -> superseded transition with only superseded_by.
      persisted_status == :published and current_status == :superseded ->
        changed_keys = changes |> Map.keys() |> Enum.reject(&(&1 == :superseded_by))

        if changed_keys == [:status] or changed_keys == [] do
          changeset
        else
          add_error(changeset, :status, "only supersede transition is allowed")
        end

      persisted_status in [:published, :canceled, :superseded] and changes != %{} ->
        add_error(changeset, :status, "published/superseded/canceled versions are immutable")

      true ->
        changeset
    end
  end
end
