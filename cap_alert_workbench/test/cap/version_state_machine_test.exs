defmodule CapAlertWorkbench.Cap.VersionStateMachineTest do
  use ExUnit.Case, async: true

  alias CapAlertWorkbench.Cap.VersionStateMachine

  test "allows the canonical lifecycle transitions" do
    assert {:ok, :in_review} = VersionStateMachine.transition(:draft, :submit)
    assert {:ok, :approved} = VersionStateMachine.transition(:in_review, :approve)
    assert {:ok, :rejected} = VersionStateMachine.transition(:in_review, :request_changes)
    assert {:ok, :rejected} = VersionStateMachine.transition(:in_review, :reject)
    assert {:ok, :published} = VersionStateMachine.transition(:approved, :publish)
    assert {:ok, :draft} = VersionStateMachine.transition(:approved, :revise)
    assert {:ok, :draft} = VersionStateMachine.transition(:rejected, :revise)
  end

  test "rejects invalid transitions without free-form strings" do
    assert {:error, {:invalid_transition, :published, :submit}} =
             VersionStateMachine.transition(:published, :submit)

    assert {:error, {:invalid_transition, :draft, :publish}} =
             VersionStateMachine.transition(:draft, :publish)

    assert {:error, {:invalid_transition, :canceled, :revise}} =
             VersionStateMachine.transition(:canceled, :revise)
  end

  test "classifies editable, immutable, publishable, correctable, cancellable states" do
    assert VersionStateMachine.editable?(:draft)
    assert VersionStateMachine.editable?(:rejected)
    refute VersionStateMachine.editable?(:published)
    refute VersionStateMachine.editable?(:approved)

    assert VersionStateMachine.immutable?(:published)
    assert VersionStateMachine.immutable?(:superseded)
    assert VersionStateMachine.immutable?(:canceled)
    refute VersionStateMachine.immutable?(:draft)

    assert VersionStateMachine.publishable?(:approved)
    refute VersionStateMachine.publishable?(:in_review)

    assert VersionStateMachine.correctable?(:published)
    assert VersionStateMachine.cancellable?(:published)
  end

  test "review staleness requires exact revision match" do
    refute VersionStateMachine.review_stale?(%{decision_revision: 3, current_revision: 3})
    assert VersionStateMachine.review_stale?(%{decision_revision: 2, current_revision: 3})
    assert VersionStateMachine.review_stale?(%{decision_revision: nil, current_revision: 1})
  end
end
