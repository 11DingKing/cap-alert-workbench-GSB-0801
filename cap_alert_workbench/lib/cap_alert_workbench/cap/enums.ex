defmodule CapAlertWorkbench.Cap.Enums do
  @moduledoc """
  Explicit enumerations for CAP 1.2 values. All values are represented as atoms
  internally and persisted as their canonical CAP strings. No free-form string
  concatenation is used for state or enumerated values.
  """

  @statuses [:actual, :exercise, :system, :test, :draft]
  @msg_types [:alert, :update, :cancel, :ack, :error]
  @scopes [:public, :restricted, :private]
  @urgencies [:immediate, :expected, :future, :past, :unknown]
  @severities [:extreme, :severe, :moderate, :minor, :unknown]
  @certainties [:observed, :likely, :possible, :unlikely, :unknown]
  @languages ~w(zh-CN en-US)

  @version_statuses [
    :draft,
    :in_review,
    :approved,
    :rejected,
    :published,
    :superseded,
    :canceled
  ]

  @review_decisions [:approved, :changes_requested, :rejected]

  @audit_actions [
    :draft_created,
    :draft_updated,
    :draft_revision_created,
    :review_submitted,
    :review_decision,
    :review_stale,
    :published,
    :publish_blocked,
    :correction_created,
    :cancellation_created,
    :xml_imported,
    :xml_exported
  ]

  @outbox_statuses [:pending, :delivered, :failed]

  def statuses, do: @statuses
  def msg_types, do: @msg_types
  def scopes, do: @scopes
  def urgencies, do: @urgencies
  def severities, do: @severities
  def certainties, do: @certainties
  def languages, do: @languages
  def version_statuses, do: @version_statuses
  def review_decisions, do: @review_decisions
  def audit_actions, do: @audit_actions
  def outbox_statuses, do: @outbox_statuses

  for value <- @statuses do
    def status_to_string(unquote(value)), do: unquote(value |> to_string() |> String.capitalize())
    def status_from_string(unquote(value |> to_string() |> String.capitalize())), do: unquote(value)
  end

  for value <- @msg_types do
    def msg_type_to_string(unquote(value)), do: unquote(value |> to_string() |> String.capitalize())
    def msg_type_from_string(unquote(value |> to_string() |> String.capitalize())), do: unquote(value)
  end

  for value <- @scopes do
    def scope_to_string(unquote(value)), do: unquote(value |> to_string() |> String.capitalize())
    def scope_from_string(unquote(value |> to_string() |> String.capitalize())), do: unquote(value)
  end

  for value <- @urgencies do
    def urgency_to_string(unquote(value)), do: unquote(value |> to_string() |> String.capitalize())
    def urgency_from_string(unquote(value |> to_string() |> String.capitalize())), do: unquote(value)
  end

  for value <- @severities do
    def severity_to_string(unquote(value)), do: unquote(value |> to_string() |> String.capitalize())
    def severity_from_string(unquote(value |> to_string() |> String.capitalize())), do: unquote(value)
  end

  for value <- @certainties do
    def certainty_to_string(unquote(value)), do: unquote(value |> to_string() |> String.capitalize())
    def certainty_from_string(unquote(value |> to_string() |> String.capitalize())), do: unquote(value)
  end

  for value <- @version_statuses do
    def version_status_to_string(unquote(value)), do: unquote(Atom.to_string(value))
    def version_status_from_string(unquote(Atom.to_string(value))), do: unquote(value)
  end

  for value <- @review_decisions do
    def review_decision_to_string(unquote(value)), do: unquote(Atom.to_string(value))
    def review_decision_from_string(unquote(Atom.to_string(value))), do: unquote(value)
  end

  for value <- @audit_actions do
    def audit_action_to_string(unquote(value)), do: unquote(Atom.to_string(value))
    def audit_action_from_string(unquote(Atom.to_string(value))), do: unquote(value)
  end

  for value <- @outbox_statuses do
    def outbox_status_to_string(unquote(value)), do: unquote(Atom.to_string(value))
    def outbox_status_from_string(unquote(Atom.to_string(value))), do: unquote(value)
  end

  def cast_status(value) when is_atom(value) and value in @statuses, do: {:ok, value}
  def cast_status(value) when is_binary(value), do: safe_cast(value, &status_from_string/1)

  def cast_msg_type(value) when is_atom(value) and value in @msg_types, do: {:ok, value}
  def cast_msg_type(value) when is_binary(value), do: safe_cast(value, &msg_type_from_string/1)

  def cast_scope(value) when is_atom(value) and value in @scopes, do: {:ok, value}
  def cast_scope(value) when is_binary(value), do: safe_cast(value, &scope_from_string/1)

  def cast_urgency(value) when is_atom(value) and value in @urgencies, do: {:ok, value}
  def cast_urgency(value) when is_binary(value), do: safe_cast(value, &urgency_from_string/1)

  def cast_severity(value) when is_atom(value) and value in @severities, do: {:ok, value}
  def cast_severity(value) when is_binary(value), do: safe_cast(value, &severity_from_string/1)

  def cast_certainty(value) when is_atom(value) and value in @certainties, do: {:ok, value}
  def cast_certainty(value) when is_binary(value), do: safe_cast(value, &certainty_from_string/1)

  def cast_language(value) when is_binary(value) and value in @languages, do: {:ok, value}
  def cast_language(value) when is_binary(value), do: :error

  defp safe_cast(value, from_string) do
    {:ok, from_string.(value)}
  rescue
    FunctionClauseError -> :error
  end
end
