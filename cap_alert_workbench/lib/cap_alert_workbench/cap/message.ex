defmodule CapAlertWorkbench.Cap.Message do
  @moduledoc """
  Immutable value object representing a CAP 1.2 alert message payload.
  All enumerated fields are explicit atoms; unknown extension fields are
  preserved in `extensions` for round-trip import/export.
  """

  alias CapAlertWorkbench.Cap.Enums

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
          area_codes: [String.t()],
          area_descriptions: [String.t()],
          references: [String.t()],
          note: String.t() | nil,
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
    area_codes: [],
    area_descriptions: [],
    references: [],
    extensions: [],
    incidents: []
  ]

  @required ~w(identifier sender sent_at status msg_type scope language urgency severity certainty event area_codes)a

  def new(attrs) do
    struct!(__MODULE__, attrs)
    |> validate()
  end

  def validate(%__MODULE__{} = message) do
    with :ok <- require_fields(message),
         :ok <- validate_enums(message) do
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

  defp validate_enums(message) do
    cond do
      not is_atom(message.status) or message.status not in Enums.statuses() ->
        {:error, :invalid_status}

      not is_atom(message.msg_type) or message.msg_type not in Enums.msg_types() ->
        {:error, :invalid_msg_type}

      not is_atom(message.scope) or message.scope not in Enums.scopes() ->
        {:error, :invalid_scope}

      not is_atom(message.urgency) or message.urgency not in Enums.urgencies() ->
        {:error, :invalid_urgency}

      not is_atom(message.severity) or message.severity not in Enums.severities() ->
        {:error, :invalid_severity}

      not is_atom(message.certainty) or message.certainty not in Enums.certainties() ->
        {:error, :invalid_certainty}

      message.language not in Enums.languages() ->
        {:error, :invalid_language}

      not match?(%DateTime{}, message.sent_at) ->
        {:error, :invalid_sent_at}

      true ->
        :ok
    end
  end

  def reference(%__MODULE__{} = message) do
    "#{message.sender},#{message.identifier},#{Calendar.strftime(message.sent_at, "%Y-%m-%dT%H:%M:%S%z")}"
  end
end
