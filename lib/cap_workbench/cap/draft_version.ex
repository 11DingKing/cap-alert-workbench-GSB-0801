defmodule CapWorkbench.Cap.DraftVersion do
  @moduledoc """
  An immutable content snapshot of an alert message at a point in the workflow.

  Every edit creates a NEW version row rather than mutating an existing one.
  Content is carried in one or more embedded `InfoBlock`s (CAP `<info>`
  segments), so a single version can describe the same event at different
  severities for different regions.

  Once a version is published its content is frozen; corrections and
  cancellations are expressed as brand new alert messages that reference the
  published one. `content_changeset/3` is only used to build a *new* row — there
  is no update changeset for content fields on purpose.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias CapWorkbench.Cap.InfoBlock

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "draft_versions" do
    field :version_number, :integer

    # Alert-level unknown / forward-compatible CAP extension fields, preserved
    # for round-trip export. (Per-info extensions live on each InfoBlock.)
    field :extensions, :map, default: %{}

    field :review_state, Ecto.Enum,
      values: CapWorkbench.Cap.Enums.review_states(),
      default: :pending

    field :reviewed_by, :string
    field :reviewed_at, :utc_datetime_usec
    field :review_comment, :string

    field :published, :boolean, default: false
    field :published_at, :utc_datetime_usec

    field :created_by, :string

    embeds_many :infos, InfoBlock, on_replace: :delete

    belongs_to :alert_message, CapWorkbench.Cap.AlertMessage

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Builds a changeset for a NEW immutable version snapshot.

  `attrs` must carry an `:infos` (or `"infos"`) list of one or more info block
  maps. `version_number`, `alert_message_id`, and `created_by` are set
  explicitly by the domain (not via user cast) and passed through `meta`.
  """
  def content_changeset(version, attrs, meta \\ %{}) do
    version
    |> cast(attrs, [:extensions])
    |> cast_embed(:infos, required: true, with: &InfoBlock.changeset/2)
    |> maybe_put_meta(meta)
    |> validate_required([:version_number, :alert_message_id, :created_by])
    |> validate_infos_present()
    |> unique_constraint([:alert_message_id, :version_number],
      name: :draft_versions_alert_message_id_version_number_index
    )
  end

  defp validate_infos_present(changeset) do
    case get_field(changeset, :infos) do
      [_ | _] -> changeset
      _ -> add_error(changeset, :infos, "at least one info block is required")
    end
  end

  defp maybe_put_meta(changeset, meta) do
    Enum.reduce([:version_number, :alert_message_id, :created_by], changeset, fn key, acc ->
      case Map.fetch(meta, key) do
        {:ok, value} -> put_change(acc, key, value)
        :error -> acc
      end
    end)
  end

  @doc """
  Changeset for advancing the review lifecycle of an EXISTING version.

  Only review-tracking fields may change here; content is untouched, preserving
  version immutability. Called exclusively by the domain layer.
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
