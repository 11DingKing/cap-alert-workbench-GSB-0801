defmodule CapAlertWorkbench.CapAlert.AlertInfo do
  @moduledoc """
  An embedded CAP `<info>` segment.

  A single alert version may carry multiple info segments (e.g. one per
  affected region, or one per language). Each segment owns its own severity,
  headline, description, area and geocodes, so a correction can raise the
  severity for one region while leaving another unchanged.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias CapAlertWorkbench.CapAlert.{Enums, Geocode}

  @primary_key false
  embedded_schema do
    field :language, :string, default: "zh-CN"
    field :event, :string
    field :urgency, Ecto.Enum, values: Enums.cap_urgencies()
    field :severity, Ecto.Enum, values: Enums.cap_severities()
    field :certainty, Ecto.Enum, values: Enums.cap_certainties()
    field :headline, :string
    field :description, :string
    field :instruction, :string
    field :area_desc, :string

    embeds_many :geocodes, Geocode, on_replace: :delete

    field :extensions, {:array, :map}, default: []
  end

  @required_fields ~w(event severity)a
  @optional_fields ~w(language urgency certainty headline description instruction area_desc extensions)a

  def changeset(info, attrs) do
    info
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> cast_embed(:geocodes, with: &Geocode.changeset/2)
    |> validate_required(@required_fields)
    |> validate_inclusion(:urgency, Enums.cap_urgencies())
    |> validate_inclusion(:severity, Enums.cap_severities())
    |> validate_inclusion(:certainty, Enums.cap_certainties())
  end
end
