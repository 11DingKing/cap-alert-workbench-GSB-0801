defmodule CapWorkbench.Cap.DraftVersion do
  @moduledoc """
  An immutable content snapshot of an alert message at a point in the workflow.

  Every edit creates a NEW version row rather than mutating an existing one.
  Once a version is published its content is frozen; corrections and
  cancellations are expressed as brand new alert messages that reference the
  published one. The `content_changeset/2` is only used to build a *new* row —
  there is no update changeset for content fields on purpose.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias CapWorkbench.Cap.Enums

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @geocode_pattern ~r/^\d{6}$/

  schema "draft_versions" do
    field :version_number, :integer

    field :headline, :string
    field :description, :string
    field :instruction, :string
    field :event, :string
    field :category, Ecto.Enum, values: Enums.categories()
    field :urgency, Ecto.Enum, values: Enums.urgencies()
    field :severity, Ecto.Enum, values: Enums.severities()
    field :certainty, Ecto.Enum, values: Enums.certainties()
    field :language, :string, default: "zh-CN"
    field :effective_at, :utc_datetime_usec
    field :onset_at, :utc_datetime_usec
    field :expires_at, :utc_datetime_usec

    field :area_description, :string
    field :geocodes, {:array, :string}, default: []

    # Forward-compatible / unknown CAP extension fields preserved for round-trip.
    field :extensions, :map, default: %{}

    field :review_state, Ecto.Enum, values: Enums.review_states(), default: :pending
    field :reviewed_by, :string
    field :reviewed_at, :utc_datetime_usec
    field :review_comment, :string

    field :published, :boolean, default: false
    field :published_at, :utc_datetime_usec

    field :created_by, :string

    belongs_to :alert_message, CapWorkbench.Cap.AlertMessage

    timestamps(type: :utc_datetime_usec)
  end

  @content_fields [
    :headline,
    :description,
    :instruction,
    :event,
    :category,
    :urgency,
    :severity,
    :certainty,
    :language,
    :effective_at,
    :onset_at,
    :expires_at,
    :area_description,
    :geocodes,
    :extensions
  ]

  @doc """
  Builds a changeset for a NEW immutable version snapshot.

  `version_number`, `alert_message_id`, and `created_by` are set explicitly by
  the domain (not via user cast) and passed through `meta`.
  """
  def content_changeset(version, attrs, meta \\ %{}) do
    version
    |> cast(attrs, @content_fields)
    |> maybe_put_meta(meta)
    |> validate_required([
      :headline,
      :description,
      :event,
      :category,
      :urgency,
      :severity,
      :certainty,
      :language,
      :area_description,
      :version_number,
      :alert_message_id,
      :created_by
    ])
    |> validate_geocodes()
    |> unique_constraint([:alert_message_id, :version_number],
      name: :draft_versions_alert_message_id_version_number_index
    )
  end

  defp maybe_put_meta(changeset, meta) do
    Enum.reduce([:version_number, :alert_message_id, :created_by], changeset, fn key, acc ->
      case Map.fetch(meta, key) do
        {:ok, value} -> put_change(acc, key, value)
        :error -> acc
      end
    end)
  end

  defp validate_geocodes(changeset) do
    geocodes = get_field(changeset, :geocodes) || []

    cond do
      geocodes == [] ->
        add_error(changeset, :geocodes, "at least one area geocode is required")

      Enum.all?(geocodes, &Regex.match?(@geocode_pattern, &1)) ->
        changeset

      true ->
        add_error(changeset, :geocodes, "each geocode must be a 6-digit region code")
    end
  end

  @doc """
  Changeset for advancing the review lifecycle of an EXISTING version.

  Only review-tracking fields may change here; content fields are untouched,
  preserving version immutability. Called exclusively by the domain layer.
  """
  def review_transition(%__MODULE__{} = version, attrs) do
    version
    |> cast(attrs, [:review_state, :reviewed_by, :reviewed_at, :review_comment])
    |> validate_required([:review_state])
  end

  @doc """
  Changeset that freezes a version as published. Sets only the publish markers;
  content remains immutable.
  """
  def publish_transition(%__MODULE__{} = version, published_at) do
    version
    |> change(%{published: true, published_at: published_at})
  end
end
