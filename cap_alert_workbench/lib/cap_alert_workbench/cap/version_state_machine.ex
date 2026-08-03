defmodule CapAlertWorkbench.Cap.VersionStateMachine do
  @moduledoc """
  Explicit state machine for CAP alert version lifecycle. Every allowed
  transition is a pattern-matched function clause. No free-form state
  strings or runtime state concatenation is permitted.

  Allowed lifecycle:

      draft --submit--> in_review
      in_review --approve--> approved
      in_review --request_changes--> rejected
      in_review --reject--> rejected
      approved --publish--> published
      approved --revise--> draft (creates a new draft revision)
      rejected --revise--> draft
      published --correct--> published (new correction version, old becomes superseded)
      published --cancel--> canceled (new cancellation version, old becomes superseded)

  Review decisions are bound to a specific content version. If the draft is
  edited after a review begins, the review is stale and cannot approve the
  new content.
  """

  @type state ::
          :draft
          | :in_review
          | :approved
          | :rejected
          | :published
          | :superseded
          | :canceled

  @type event ::
          :submit
          | :approve
          | :request_changes
          | :reject
          | :revise
          | :publish
          | :correct
          | :cancel

  @transitions %{
    {:draft, :submit} => :in_review,
    {:in_review, :approve} => :approved,
    {:in_review, :request_changes} => :rejected,
    {:in_review, :reject} => :rejected,
    {:approved, :revise} => :draft,
    {:rejected, :revise} => :draft,
    {:approved, :publish} => :published
  }

  @doc "Returns the next state for a valid (state, event) pair."
  @spec transition(state(), event()) :: {:ok, state()} | {:error, :invalid_transition}
  for {{from, event}, to} <- @transitions do
    def transition(unquote(from), unquote(event)), do: {:ok, unquote(to)}
  end

  def transition(state, event) when is_atom(state) and is_atom(event) do
    {:error, {:invalid_transition, state, event}}
  end

  @doc "Returns true when a version in the given state may be edited by an author."
  def editable?(:draft), do: true
  def editable?(:in_review), do: true
  def editable?(:rejected), do: true
  def editable?(_), do: false

  @doc "Returns true when a version in the given state is immutable history."
  def immutable?(:published), do: true
  def immutable?(:superseded), do: true
  def immutable?(:canceled), do: true
  def immutable?(_), do: false

  @doc "Returns true when a version in the given state may be published."
  def publishable?(:approved), do: true
  def publishable?(_), do: false

  @doc "Returns true when a version in the given state may spawn a correction."
  def correctable?(:published), do: true
  def correctable?(_), do: false

  @doc "Returns true when a version in the given state may spawn a cancellation."
  def cancellable?(:published), do: true
  def cancellable?(_), do: false

  @doc "Whether a review decision can still apply to a draft at the given revision."
  def review_stale?(%{decision_revision: dr, current_revision: cr})
      when is_integer(dr) and is_integer(cr) do
    dr != cr
  end

  def review_stale?(_), do: true

  def all_transitions, do: @transitions
end
