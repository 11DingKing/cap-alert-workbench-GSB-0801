defmodule CapAlertWorkbench.Cap.Info do
  @moduledoc """
  One CAP `<info>` segment. A CAP alert may contain multiple info segments so
  that different areas can carry different severities, headlines or
  descriptions within a single message (for example, one area at `Severe` and
  a neighbouring area at `Extreme`).

  Each segment owns its own urgency/severity/certainty, language, event text
  and a list of areas. The top-level `Message` carries shared fields
  (identifier, sender, sent, status, msgType, scope, references...).
  """

  alias CapAlertWorkbench.Cap.Enums

  @type area :: %{
          code: String.t(),
          description: String.t()
        }

  @type t :: %__MODULE__{
          language: String.t(),
          event: String.t(),
          urgency: :immediate | :expected | :future | :past | :unknown,
          severity: :extreme | :severe | :moderate | :minor | :unknown,
          certainty: :observed | :likely | :possible | :unlikely | :unknown,
          headline: String.t() | nil,
          description: String.t() | nil,
          instruction: String.t() | nil,
          category: String.t(),
          areas: [area()]
        }

  @enforce_keys [:language, :event, :urgency, :severity, :certainty, :areas]
  defstruct [
    :language,
    :event,
    :urgency,
    :severity,
    :certainty,
    :headline,
    :description,
    :instruction,
    category: "Met",
    areas: []
  ]

  @doc "Validates an info segment."
  def validate(%__MODULE__{} = info) do
    cond do
      info.language not in Enums.languages() ->
        {:error, :invalid_language}

      info.urgency not in Enums.urgencies() ->
        {:error, :invalid_urgency}

      info.severity not in Enums.severities() ->
        {:error, :invalid_severity}

      info.certainty not in Enums.certainties() ->
        {:error, :invalid_certainty}

      info.areas == [] ->
        {:error, :info_requires_area}

      not Enum.all?(info.areas, &is_map/1) ->
        {:error, :invalid_areas}

      true ->
        :ok
    end
  end

  @doc "Returns the area codes contained in this info segment."
  def area_codes(%__MODULE__{areas: areas}), do: Enum.map(areas, & &1.code)

  @doc "Returns the area descriptions contained in this info segment."
  def area_descriptions(%__MODULE__{areas: areas}), do: Enum.map(areas, & &1.description)
end
