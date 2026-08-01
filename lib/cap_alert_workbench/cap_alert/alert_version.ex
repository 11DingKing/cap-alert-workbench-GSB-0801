defmodule CapAlertWorkbench.CapAlert.AlertVersion do
  @moduledoc """
  An immutable-ish version of an alert. Content may only change while the
  workflow state is `:draft` or `:changes_requested`; updates use an
  optimistic lock (`lock_version`) to detect concurrent edits.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias CapAlertWorkbench.CapAlert.{Enums, Geocode}

  @primary_key {:id, :id, autogenerate: true}

  schema "alert_versions" do
    field :alert_identifier, :string
    field :version_number, :integer
    field :lock_version, :integer, default: 1

    field :sender, :string
    field :sent, :utc_datetime
    field :status, Ecto.Enum, values: Enums.cap_statuses()
    field :msg_type, Ecto.Enum, values: Enums.cap_msg_types()
    field :scope, Ecto.Enum, values: Enums.cap_scopes()
    field :language, :string

    field :event, :string
    field :headline, :string
    field :description, :string
    field :instruction, :string

    field :urgency, Ecto.Enum, values: Enums.cap_urgencies()
    field :severity, Ecto.Enum, values: Enums.cap_severities()
    field :certainty, Ecto.Enum, values: Enums.cap_certainties()

    field :area_desc, :string
    embeds_many :geocodes, Geocode, on_replace: :delete

    field :references, :string
    field :extensions, {:array, :map}, default: []

    field :workflow_state, Ecto.Enum, values: Enums.workflow_states()
    field :review_comment, :string
    field :reviewed_by, :string
    field :reviewed_at, :utc_datetime
    field :published_at, :utc_datetime

    field :based_on_version_id, :integer
    field :xml_payload, :string

    belongs_to :alert, CapAlertWorkbench.CapAlert.Alert,
      foreign_key: :alert_identifier,
      references: :identifier,
      define_field: false

    belongs_to :based_on, __MODULE__,
      foreign_key: :based_on_version_id,
      references: :id,
      define_field: false

    timestamps(type: :utc_datetime)
  end

  @required_fields ~w(alert_identifier version_number sender sent status msg_type scope workflow_state)a
  @optional_fields ~w(lock_version language event headline description instruction urgency severity
    certainty area_desc references extensions review_comment reviewed_by reviewed_at
    published_at based_on_version_id xml_payload)a

  def changeset(version, attrs) do
    version
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> cast_embed(:geocodes, with: &Geocode.changeset/2)
    |> validate_required(@required_fields)
    |> validate_inclusion(:status, Enums.cap_statuses())
    |> validate_inclusion(:msg_type, Enums.cap_msg_types())
    |> validate_inclusion(:scope, Enums.cap_scopes())
    |> validate_inclusion(:workflow_state, Enums.workflow_states())
    |> validate_references()
    |> unique_constraint([:alert_identifier, :version_number])
    |> optimistic_lock(:lock_version)
  end

  defp validate_references(changeset) do
    case get_field(changeset, :msg_type) do
      msg_type when msg_type in ~w(update cancel)a ->
        validate_required(changeset, [:references], message: "更正/解除消息必须包含引用")

      _ ->
        changeset
    end
  end
end
