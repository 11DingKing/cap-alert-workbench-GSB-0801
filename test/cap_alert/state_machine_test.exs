defmodule CapAlertWorkbench.CapAlert.StateMachineTest do
  use ExUnit.Case, async: true

  alias CapAlertWorkbench.CapAlert.StateMachine

  test "allowed transitions" do
    assert {:ok, :in_review} = StateMachine.transition(:draft, :submit)
    assert {:ok, :in_review} = StateMachine.transition(:changes_requested, :submit)
    assert {:ok, :approved} = StateMachine.transition(:in_review, :approve)
    assert {:ok, :changes_requested} = StateMachine.transition(:in_review, :reject)
    assert {:ok, :draft} = StateMachine.transition(:in_review, :withdraw)
    assert {:ok, :published} = StateMachine.transition(:approved, :publish)
    assert {:ok, :superseded} = StateMachine.transition(:published, :supersede)
    assert {:ok, :cancelled} = StateMachine.transition(:published, :cancel)
  end

  test "rejects invalid transitions" do
    assert {:error, {:invalid_transition, :draft, :publish}} =
             StateMachine.transition(:draft, :publish)

    assert {:error, {:invalid_transition, :published, :submit}} =
             StateMachine.transition(:published, :submit)

    assert {:error, {:invalid_transition, :approved, :reject}} =
             StateMachine.transition(:approved, :reject)
  end

  test "editable? and locked?" do
    assert StateMachine.editable?(:draft)
    assert StateMachine.editable?(:changes_requested)
    refute StateMachine.editable?(:in_review)
    refute StateMachine.editable?(:published)

    assert StateMachine.locked?(:in_review)
    assert StateMachine.locked?(:approved)
    assert StateMachine.locked?(:published)
    assert StateMachine.locked?(:superseded)
    assert StateMachine.locked?(:cancelled)
    refute StateMachine.locked?(:draft)
  end

  test "reviewable? requires in_review and latest" do
    assert StateMachine.reviewable?(:in_review, true)
    refute StateMachine.reviewable?(:in_review, false)
    refute StateMachine.reviewable?(:approved, true)
    refute StateMachine.reviewable?(:draft, true)
  end

  test "publishable? requires approved and latest" do
    assert StateMachine.publishable?(:approved, true)
    refute StateMachine.publishable?(:approved, false)
    refute StateMachine.publishable?(:published, true)
    refute StateMachine.publishable?(:draft, true)
  end

  test "transition! raises on invalid" do
    assert_raise ArgumentError, fn -> StateMachine.transition!(:draft, :publish) end
  end
end
