defmodule CapWorkbench.Cap.Enums do
  @moduledoc """
  Single source of truth for every constrained CAP value in the system.

  The domain, the state machine, the Ecto schemas, and the XML layer all read
  their allowed values from here. Values are represented as explicit atoms so
  that the rest of the system can pattern match on them exhaustively. Free
  string assembly of any of these values is forbidden anywhere in the codebase.
  """

  # CAP <status>
  @statuses [:actual, :exercise, :system, :test, :draft]
  # CAP <msgType>
  @msg_types [:alert, :update, :cancel, :ack, :error]
  # CAP <scope>
  @scopes [:public, :restricted, :private]
  # CAP <info><category>
  @categories [
    :geo,
    :met,
    :safety,
    :security,
    :rescue,
    :fire,
    :health,
    :env,
    :transport,
    :infra,
    :cbrne,
    :other
  ]
  # CAP <info><urgency>
  @urgencies [:immediate, :expected, :future, :past, :unknown]
  # CAP <info><severity>
  @severities [:extreme, :severe, :moderate, :minor, :unknown]
  # CAP <info><certainty>
  @certainties [:observed, :likely, :possible, :unlikely, :unknown]

  # Editorial workflow states for an alert message.
  @workflow_states [:drafting, :in_review, :published, :superseded]
  # Per-version review states.
  @review_states [:pending, :in_review, :approved, :rejected]
  # Audit actions.
  @audit_actions [
    :draft_created,
    :version_saved,
    :submitted_for_review,
    :approved,
    :rejected,
    :published,
    :correction_created,
    :cancellation_created,
    :superseded
  ]
  # Outbox event types.
  @outbox_events [:published, :corrected, :cancelled]
  # Outbox delivery states.
  @outbox_states [:pending, :delivered, :failed]

  def statuses, do: @statuses
  def msg_types, do: @msg_types
  def scopes, do: @scopes
  def categories, do: @categories
  def urgencies, do: @urgencies
  def severities, do: @severities
  def certainties, do: @certainties
  def workflow_states, do: @workflow_states
  def review_states, do: @review_states
  def audit_actions, do: @audit_actions
  def outbox_events, do: @outbox_events
  def outbox_states, do: @outbox_states

  @doc """
  Maps a domain atom to the canonical CAP wire token (used in XML).

  CAP tokens are TitleCase (e.g. `:immediate -> "Immediate"`, `:cbrne -> "CBRNE"`).
  Only known atoms are accepted; unknown values raise, preventing silent
  string coercion.
  """
  def to_cap_token(:cbrne), do: "CBRNE"

  def to_cap_token(value) when is_atom(value) do
    value
    |> Atom.to_string()
    |> String.split("_")
    |> Enum.map_join("", &capitalize/1)
  end

  @doc """
  Parses a CAP wire token back into a known domain atom for the given field.

  Returns `{:ok, atom}` when the token corresponds to a permitted value, or
  `:error` otherwise. Never calls `String.to_atom/1` on external input.
  """
  def from_cap_token(field, token) when is_binary(token) do
    normalized = normalize_token(token)

    field
    |> allowed_for()
    |> Enum.find(fn atom -> normalize_token(to_cap_token(atom)) == normalized end)
    |> case do
      nil -> :error
      atom -> {:ok, atom}
    end
  end

  defp allowed_for(:status), do: @statuses
  defp allowed_for(:msg_type), do: @msg_types
  defp allowed_for(:scope), do: @scopes
  defp allowed_for(:category), do: @categories
  defp allowed_for(:urgency), do: @urgencies
  defp allowed_for(:severity), do: @severities
  defp allowed_for(:certainty), do: @certainties

  defp normalize_token(token), do: token |> String.trim() |> String.downcase()

  defp capitalize("cbrne"), do: "CBRNE"
  defp capitalize(part), do: String.capitalize(part)
end
