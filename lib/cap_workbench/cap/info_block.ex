defmodule CapWorkbench.Cap.InfoBlock do
  @moduledoc """
  A single CAP `<info>` block: one hazard description scoped to one area.

  A CAP alert may carry several `<info>` blocks — e.g. the same event at
  different severities for different regions. Each block owns its own area,
  severity, headline and description, so a correction can raise only 440900 to
  `Extreme` while 440800 stays `Severe` by splitting into two blocks.

  Blocks are embedded (JSON) inside an immutable `DraftVersion`; they are never
  mutated in place — a new version embeds a fresh set of blocks.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias CapWorkbench.Cap.Enums

  @primary_key {:id, :binary_id, autogenerate: true}

  @geocode_pattern ~r/^\d{6}$/

  @derive {Jason.Encoder,
           only: [
             :id,
             :language,
             :category,
             :event,
             :urgency,
             :severity,
             :certainty,
             :headline,
             :description,
             :instruction,
             :effective_at,
             :onset_at,
             :expires_at,
             :area_description,
             :geocodes,
             :extensions
           ]}

  embedded_schema do
    field :language, :string, default: "zh-CN"
    field :category, Ecto.Enum, values: Enums.categories()
    field :event, :string
    field :urgency, Ecto.Enum, values: Enums.urgencies()
    field :severity, Ecto.Enum, values: Enums.severities()
    field :certainty, Ecto.Enum, values: Enums.certainties()
    field :headline, :string
    field :description, :string
    field :instruction, :string
    field :effective_at, :utc_datetime_usec
    field :onset_at, :utc_datetime_usec
    field :expires_at, :utc_datetime_usec

    field :area_description, :string
    field :geocodes, {:array, :string}, default: []

    # Per-info unknown / forward-compatible CAP extension fields, preserved for
    # round-trip export.
    field :extensions, :map, default: %{}
  end

  @cast_fields [
    :language,
    :category,
    :event,
    :urgency,
    :severity,
    :certainty,
    :headline,
    :description,
    :instruction,
    :effective_at,
    :onset_at,
    :expires_at,
    :area_description,
    :geocodes,
    :extensions
  ]

  def changeset(info, attrs) do
    info
    |> cast(attrs, @cast_fields)
    |> validate_required([
      :language,
      :category,
      :event,
      :urgency,
      :severity,
      :certainty,
      :headline,
      :description,
      :area_description
    ])
    |> validate_geocodes()
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
end
