defmodule CapAlertWorkbench.CapAlert.StateMachine do
  @moduledoc """
  Pure state machine for the editorial workflow.

  Every transition is expressed as an explicit `{state, action} -> next_state`
  clause. There is no dynamic string construction of states. Callers receive
  `{:ok, next_state}` or `{:error, reason}`.
  """

  alias CapAlertWorkbench.CapAlert.Enums

  @type state :: Enums.workflow_state()
  @type action :: Enums.workflow_action()

  @editable_states [:draft, :changes_requested]

  @doc """
  States in which the version content may be edited.
  """
  def editable_states, do: @editable_states

  @doc """
  Returns true when the given state permits content editing.
  """
  def editable?(state) when state in @editable_states, do: true
  def editable?(_state), do: false

  @doc """
  Returns true when the given state is terminal/immutable for content.
  """
  def locked?(state)
      when state in ~w(in_review approved published superseded cancelled withdrawn)a,
      do: true

  def locked?(_state), do: false

  @doc """
  Attempt a transition. Allowed transitions:

    * draft | changes_requested --submit--> in_review
    * in_review --approve--> approved
    * in_review --reject--> changes_requested
    * in_review --withdraw--> draft
    * approved --publish--> published
    * published --supersede--> superseded   (a correction was published)
    * published --cancel--> cancelled       (a cancellation was published)
  """
  @spec transition(state(), action()) :: {:ok, state()} | {:error, term()}
  def transition(:draft, :submit), do: {:ok, :in_review}
  def transition(:changes_requested, :submit), do: {:ok, :in_review}
  def transition(:in_review, :approve), do: {:ok, :approved}
  def transition(:in_review, :reject), do: {:ok, :changes_requested}
  def transition(:in_review, :withdraw), do: {:ok, :draft}
  def transition(:approved, :publish), do: {:ok, :published}
  def transition(:published, :supersede), do: {:ok, :superseded}
  def transition(:published, :cancel), do: {:ok, :cancelled}

  def transition(state, action) do
    {:error, {:invalid_transition, state, action}}
  end

  @doc """
  Raising variant of `transition/2`.
  """
  @spec transition!(state(), action()) :: state()
  def transition!(state, action) do
    case transition(state, action) do
      {:ok, next} -> next
      {:error, reason} -> raise ArgumentError, "invalid transition: #{inspect(reason)}"
    end
  end

  @doc """
  Guards whether a review decision may be applied. A review is only valid for
  the *latest* version while it is still `:in_review`. This prevents stale review
  conclusions from a previous draft from winning over a newer draft.
  """
  @spec reviewable?(state(), boolean()) :: boolean()
  def reviewable?(:in_review, is_latest?) when is_boolean(is_latest?) do
    is_latest?
  end

  def reviewable?(_state, _is_latest?), do: false

  @doc """
  Guards whether a version may be published. It must be `:approved` and be the
  latest version of the alert.
  """
  @spec publishable?(state(), boolean()) :: boolean()
  def publishable?(:approved, is_latest?) when is_boolean(is_latest?) do
    is_latest?
  end

  def publishable?(_state, _is_latest?), do: false
end
