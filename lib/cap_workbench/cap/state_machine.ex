defmodule CapWorkbench.Cap.StateMachine do
  @moduledoc """
  Pure editorial state machine for CAP alert messages.

  All transition rules live here as explicit clauses matched on `{state, event}`.
  There is no free-form string handling: states and events are atoms drawn from
  `CapWorkbench.Cap.Enums`, and every legal transition is written out. Anything
  not matched is an illegal transition and returns `{:error, ...}`.

  This module performs NO database work and has NO side effects. The context
  layer consults it to decide whether an action is allowed, then performs the
  persistence. LiveView and controllers never call `Repo` to change state; they
  go through the context, which goes through here.

  ## Message-level workflow states

    :drafting    - one or more draft versions exist; latest may be edited/resubmitted
    :in_review   - the latest version has been submitted and awaits a reviewer
    :published   - a reviewed version has been published; content is now frozen
    :superseded  - a later correction/cancellation message supersedes this one

  ## Version-level review states

    :pending   -> :in_review -> :approved | :rejected
    A rejected or (re)edited version drops the message back to :drafting.
  """

  alias CapWorkbench.Cap.{AlertMessage, DraftVersion}

  @type workflow_state :: :drafting | :in_review | :published | :superseded
  @type event ::
          :save_version
          | :submit_for_review
          | :approve
          | :reject
          | :publish
          | :supersede

  @doc """
  Returns the message workflow states from which content editing (creating a new
  version) is permitted. Published/superseded messages are frozen.
  """
  def editable_states, do: [:drafting, :in_review]

  @doc """
  Decides the next message workflow state for a given event.

  Returns `{:ok, next_state}` for a legal transition or
  `{:error, {:illegal_transition, state, event}}` otherwise.
  """
  @spec transition(workflow_state(), event()) ::
          {:ok, workflow_state()} | {:error, {:illegal_transition, workflow_state(), event()}}
  # Editing/saving a new version keeps (or returns) the message in :drafting.
  def transition(:drafting, :save_version), do: {:ok, :drafting}
  def transition(:in_review, :save_version), do: {:ok, :drafting}

  # Submitting the latest version for review.
  def transition(:drafting, :submit_for_review), do: {:ok, :in_review}

  # Reviewer decisions.
  def transition(:in_review, :approve), do: {:ok, :in_review}
  def transition(:in_review, :reject), do: {:ok, :drafting}

  # Publishing an approved version.
  def transition(:in_review, :publish), do: {:ok, :published}

  # A published message can be superseded by a correction/cancellation.
  def transition(:published, :supersede), do: {:ok, :superseded}

  # Everything else is illegal.
  def transition(state, event), do: {:error, {:illegal_transition, state, event}}

  @doc """
  Guards whether the latest version may be edited given the message state.
  """
  def can_edit?(%AlertMessage{workflow_state: state}), do: state in editable_states()

  @doc """
  Guards whether a message may be submitted for review.

  Requires the message to be in `:drafting` and the given version to be the
  latest, pending/rejected (i.e. not already approved or published).
  """
  def can_submit?(%AlertMessage{workflow_state: :drafting}, %DraftVersion{
        review_state: review_state,
        published: false
      })
      when review_state in [:pending, :rejected],
      do: true

  def can_submit?(_message, _version), do: false

  @doc """
  Guards whether a review decision may be recorded for a version.

  The message must be `:in_review` and the version must be the one under review
  (`:in_review` review_state).
  """
  def can_review?(%AlertMessage{workflow_state: :in_review}, %DraftVersion{
        review_state: :in_review
      }),
      do: true

  def can_review?(_message, _version), do: false

  @doc """
  Guards whether a version may be published.

  Only an approved, not-yet-published version whose message is `:in_review` may
  publish. This is the sole path by which content becomes public.
  """
  def can_publish?(%AlertMessage{workflow_state: :in_review}, %DraftVersion{
        review_state: :approved,
        published: false
      }),
      do: true

  def can_publish?(_message, _version), do: false

  @doc """
  Guards whether a correction or cancellation may be derived from a message.

  Only a currently `:published` message can be corrected or cancelled.
  """
  def can_derive?(%AlertMessage{workflow_state: :published}), do: true
  def can_derive?(_message), do: false
end
