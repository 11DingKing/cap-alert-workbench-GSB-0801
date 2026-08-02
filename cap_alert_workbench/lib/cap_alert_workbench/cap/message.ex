defmodule CapAlertWorkbench.Cap.Message do
  @moduledoc """
  Immutable value object representing a CAP 1.2 alert message.

  Alert-level fields (identifier, sender, sent, status, msgType, scope,
  references) live here. All area-specific content — urgency, severity,
  certainty, event, headline, description, instruction — lives in one or more
  `CapAlertWorkbench.Cap.Info` segments. This allows a single alert to give,
  for example, area `440800` a `Severe` segment and area `440900` an
  `Extreme` segment.

  The top-level `urgency/severity/certainty/event/headline/description`
  fields are retained as convenience defaults for single-info messages; they
  are populated from the first info segment by `new/1` and are not serialized
  directly (serialization always emits `<info>` elements).
  """

  alias CapAlertWorkbench.Cap.{Enums, Info}

  @type extension :: {String.t(), [map()], String.t() | nil}

  @type t :: %__MODULE__{
          identifier: String.t(),
          sender: String.t(),
          sent_at: DateTime.t(),
          status: :actual | :exercise | :system | :test | :draft,
          msg_type: :alert | :update | :cancel | :ack | :error,
          scope: :public | :restricted | :private,
          language: String.t(),
          urgency: :immediate | :expected | :future | :past | :unknown,
          severity: :extreme | :severe | :moderate | :minor | :unknown,
          certainty: :observed | :likely | :possible | :unlikely | :unknown,
          event: String.t(),
          headline: String.t() | nil,
          description: String.t() | nil,
          instruction: String.t() | nil,
          note: String.t() | nil,
          infos: [Info.t()],
          area_codes: [String.t()],
          area_descriptions: [String.t()],
          references: [String.t()],
          extensions: [extension()],
          incidents: [map()]
        }

  defstruct [
    :identifier,
    :sender,
    :sent_at,
    :status,
    :msg_type,
    :scope,
    :language,
    :urgency,
    :severity,
    :certainty,
    :event,
    :headline,
    :description,
    :instruction,
    :note,
    references: [],
    extensions: [],
    incidents: [],
    infos: [],
    area_codes: [],
    area_descriptions: []
  ]

  @required ~w(identifier sender sent_at status msg_type scope language)a

  def new(attrs) do
    struct!(__MODULE__, attrs)
    |> normalize_infos()
    |> validate()
  end

  def validate(%__MODULE__{} = message) do
    with :ok <- require_fields(message),
         :ok <- validate_alert_enums(message),
         :ok <- validate_infos(message) do
      {:ok, message}
    end
  end

  defp require_fields(message) do
    missing =
      Enum.filter(@required, fn key ->
        value = Map.get(message, key)
        value in [nil, "", []]
      end)

    if missing == [] do
      :ok
    else
      {:error, {:missing_fields, missing}}
    end
  end

  defp validate_alert_enums(message) do
    cond do
      not is_atom(message.status) or message.status not in Enums.statuses() ->
        {:error, :invalid_status}

      not is_atom(message.msg_type) or message.msg_type not in Enums.msg_types() ->
        {:error, :invalid_msg_type}

      not is_atom(message.scope) or message.scope not in Enums.scopes() ->
        {:error, :invalid_scope}

      message.language not in Enums.languages() ->
        {:error, :invalid_language}

      not match?(%DateTime{}, message.sent_at) ->
        {:error, :invalid_sent_at}

      true ->
        :ok
    end
  end

  defp validate_infos(%__MODULE__{infos: infos}) do
    if infos == [] do
      {:error, :at_least_one_info_required}
    else
      Enum.reduce_while(infos, :ok, fn info, :ok ->
        case Info.validate(info) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)
    end
  end

  @doc """
  Returns all area codes across all info segments in document order.
  """
  def area_codes(%__MODULE__{infos: infos}) do
    Enum.flat_map(infos, &Info.area_codes/1)
  end

  @doc """
  Returns all area descriptions across all info segments in document order.
  """
  def area_descriptions(%__MODULE__{infos: infos}) do
    Enum.flat_map(infos, &Info.area_descriptions/1)
  end

  @doc """
  Returns the info segment that contains the given area code, if any.
  """
  def info_for_area(%__MODULE__{infos: infos}, code) do
    Enum.find(infos, fn info ->
      code in Info.area_codes(info)
    end)
  end

  # When constructing a message from legacy fields, build a single info segment
  # from the top-level values. Existing callers (and persisted payloads) may
  # still pass area_codes/area_descriptions directly.
  defp normalize_infos(%__MODULE__{infos: [_ | _]} = message) do
    %{message | area_codes: area_codes(message), area_descriptions: area_descriptions(message)}
  end

  defp normalize_infos(%__MODULE__{} = message) do
    codes = Map.get(message, :area_codes) || message.area_codes || []
    descs = Map.get(message, :area_descriptions) || message.area_descriptions || []

    areas =
      codes
      |> Enum.zip(descs)
      |> Enum.map(fn {code, desc} -> %{code: code, description: desc || code} end)

    if areas == [] do
      message
    else
      info = %Info{
        language: message.language,
        event: message.event,
        urgency: message.urgency,
        severity: message.severity,
        certainty: message.certainty,
        headline: message.headline,
        description: message.description,
        instruction: message.instruction,
        areas: areas
      }

      %{message | infos: [info], area_codes: codes, area_descriptions: descs}
    end
  end

  def reference(%__MODULE__{} = message) do
    "#{message.sender},#{message.identifier}," <>
      CapAlertWorkbench.Cap.Xml.Codec.format_ref_time(message.sent_at)
  end
end
