defmodule CapAlertWorkbench.CapAlert.Enums do
  @moduledoc """
  Explicit enumerations for CAP 1.2 fields and the editorial workflow.

  All values are defined once here and referenced by name. Persistence uses the
  canonical CAP string values; the application code never constructs status or
  msgType strings by concatenation.
  """

  @type cap_status :: :actual | :exercise | :system | :test | :draft
  @type cap_msg_type :: :alert | :update | :cancel | :ack | :error
  @type cap_scope :: :public | :restricted | :private
  @type cap_urgency :: :immediate | :expected | :future | :past | :unknown
  @type cap_severity :: :extreme | :severe | :moderate | :minor | :unknown
  @type cap_certainty :: :observed | :likely | :possible | :unlikely | :unknown

  @type workflow_state ::
          :draft
          | :in_review
          | :changes_requested
          | :approved
          | :published
          | :superseded
          | :cancelled
          | :withdrawn

  @type workflow_action ::
          :submit
          | :approve
          | :reject
          | :publish
          | :withdraw
          | :supersede
          | :cancel

  @type alert_state :: :active | :cancelled

  @type outbox_status :: :pending | :published | :failed

  cap_statuses = ~w(actual exercise system test draft)a
  cap_msg_types = ~w(alert update cancel ack error)a
  cap_scopes = ~w(public restricted private)a
  cap_urgencies = ~w(immediate expected future past unknown)a
  cap_severities = ~w(extreme severe moderate minor unknown)a
  cap_certainties = ~w(observed likely possible unlikely unknown)a

  workflow_states =
    ~w(draft in_review changes_requested approved published superseded cancelled withdrawn)a

  workflow_actions = ~w(submit approve reject publish withdraw supersede cancel)a
  alert_states = ~w(active cancelled)a
  outbox_statuses = ~w(pending published failed)a

  @cap_status_values cap_statuses
  @cap_msg_type_values cap_msg_types
  @cap_scope_values cap_scopes
  @cap_urgency_values cap_urgencies
  @cap_severity_values cap_severities
  @cap_certainty_values cap_certainties
  @workflow_state_values workflow_states
  @workflow_action_values workflow_actions
  @alert_state_values alert_states
  @outbox_status_values outbox_statuses

  @cap_status_strings Map.new(cap_statuses, &{&1, Atom.to_string(&1) |> String.capitalize()})
  @cap_msg_type_strings Map.new(cap_msg_types, &{&1, Atom.to_string(&1) |> String.capitalize()})
  @cap_scope_strings Map.new(cap_scopes, &{&1, Atom.to_string(&1) |> String.capitalize()})
  @cap_urgency_strings Map.new(cap_urgencies, &{&1, Atom.to_string(&1) |> String.capitalize()})
  @cap_severity_strings Map.new(cap_severities, &{&1, Atom.to_string(&1) |> String.capitalize()})
  @cap_certainty_strings Map.new(
                           cap_certainties,
                           &{&1, Atom.to_string(&1) |> String.capitalize()}
                         )

  @workflow_state_strings Map.new(workflow_states, fn s ->
                            {s, s |> Atom.to_string() |> String.replace("_", " ")}
                          end)

  @doc "List of allowed CAP status atoms."
  def cap_statuses, do: @cap_status_values
  def cap_msg_types, do: @cap_msg_type_values
  def cap_scopes, do: @cap_scope_values
  def cap_urgencies, do: @cap_urgency_values
  def cap_severities, do: @cap_severity_values
  def cap_certainties, do: @cap_certainty_values
  def workflow_states, do: @workflow_state_values
  def workflow_actions, do: @workflow_action_values
  def alert_states, do: @alert_state_values
  def outbox_statuses, do: @outbox_status_values

  @doc "Canonical CAP string for a status atom (e.g. :actual -> \"Actual\")."
  for {atom, string} <- @cap_status_strings do
    def cap_status_string(unquote(atom)), do: unquote(string)
  end

  for {atom, string} <- @cap_msg_type_strings do
    def cap_msg_type_string(unquote(atom)), do: unquote(string)
  end

  for {atom, string} <- @cap_scope_strings do
    def cap_scope_string(unquote(atom)), do: unquote(string)
  end

  for {atom, string} <- @cap_urgency_strings do
    def cap_urgency_string(unquote(atom)), do: unquote(string)
  end

  for {atom, string} <- @cap_severity_strings do
    def cap_severity_string(unquote(atom)), do: unquote(string)
  end

  for {atom, string} <- @cap_certainty_strings do
    def cap_certainty_string(unquote(atom)), do: unquote(string)
  end

  for {atom, string} <- @workflow_state_strings do
    def workflow_state_string(unquote(atom)), do: unquote(string)
  end

  @doc "Parse a CAP status string into its atom, or :error."
  for atom <- cap_statuses do
    def parse_cap_status(unquote(Atom.to_string(atom) |> String.capitalize())),
      do: {:ok, unquote(atom)}
  end

  def parse_cap_status(_), do: :error

  for atom <- cap_msg_types do
    def parse_cap_msg_type(unquote(Atom.to_string(atom) |> String.capitalize())),
      do: {:ok, unquote(atom)}
  end

  def parse_cap_msg_type(_), do: :error

  for atom <- cap_scopes do
    def parse_cap_scope(unquote(Atom.to_string(atom) |> String.capitalize())),
      do: {:ok, unquote(atom)}
  end

  def parse_cap_scope(_), do: :error

  for atom <- cap_urgencies do
    def parse_cap_urgency(unquote(Atom.to_string(atom) |> String.capitalize())),
      do: {:ok, unquote(atom)}
  end

  def parse_cap_urgency(_), do: :error

  for atom <- cap_severities do
    def parse_cap_severity(unquote(Atom.to_string(atom) |> String.capitalize())),
      do: {:ok, unquote(atom)}
  end

  def parse_cap_severity(_), do: :error

  for atom <- cap_certainties do
    def parse_cap_certainty(unquote(Atom.to_string(atom) |> String.capitalize())),
      do: {:ok, unquote(atom)}
  end

  def parse_cap_certainty(_), do: :error

  for atom <- workflow_states do
    def parse_workflow_state(unquote(Atom.to_string(atom))), do: {:ok, unquote(atom)}
  end

  def parse_workflow_state(_), do: :error

  for atom <- alert_states do
    def parse_alert_state(unquote(Atom.to_string(atom))), do: {:ok, unquote(atom)}
  end

  def parse_alert_state(_), do: :error

  for atom <- outbox_statuses do
    def parse_outbox_status(unquote(Atom.to_string(atom))), do: {:ok, unquote(atom)}
  end

  def parse_outbox_status(_), do: :error
end
