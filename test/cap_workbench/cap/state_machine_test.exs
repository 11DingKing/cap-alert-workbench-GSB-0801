defmodule CapWorkbench.Cap.StateMachineTest do
  use ExUnit.Case, async: true

  alias CapWorkbench.Cap.{AlertMessage, DraftVersion, StateMachine}

  describe "transition/2" do
    test "drafting can save and submit" do
      assert {:ok, :drafting} = StateMachine.transition(:drafting, :save_version)
      assert {:ok, :in_review} = StateMachine.transition(:drafting, :submit_for_review)
    end

    test "in_review approves (stays), rejects (back to drafting), publishes" do
      assert {:ok, :in_review} = StateMachine.transition(:in_review, :approve)
      assert {:ok, :drafting} = StateMachine.transition(:in_review, :reject)
      assert {:ok, :published} = StateMachine.transition(:in_review, :publish)
    end

    test "saving a new version while in_review drops back to drafting" do
      assert {:ok, :drafting} = StateMachine.transition(:in_review, :save_version)
    end

    test "published can be superseded but not edited/published again" do
      assert {:ok, :superseded} = StateMachine.transition(:published, :supersede)

      assert {:error, {:illegal_transition, :published, :publish}} =
               StateMachine.transition(:published, :publish)

      assert {:error, {:illegal_transition, :published, :save_version}} =
               StateMachine.transition(:published, :save_version)
    end

    test "superseded is terminal" do
      for event <- [:save_version, :submit_for_review, :approve, :publish, :supersede] do
        assert {:error, {:illegal_transition, :superseded, ^event}} =
                 StateMachine.transition(:superseded, event)
      end
    end

    test "cannot publish straight from drafting" do
      assert {:error, {:illegal_transition, :drafting, :publish}} =
               StateMachine.transition(:drafting, :publish)
    end
  end

  describe "guards" do
    test "can_edit? only in drafting/in_review" do
      assert StateMachine.can_edit?(%AlertMessage{workflow_state: :drafting})
      assert StateMachine.can_edit?(%AlertMessage{workflow_state: :in_review})
      refute StateMachine.can_edit?(%AlertMessage{workflow_state: :published})
      refute StateMachine.can_edit?(%AlertMessage{workflow_state: :superseded})
    end

    test "can_publish? requires in_review message + approved unpublished version" do
      msg = %AlertMessage{workflow_state: :in_review}
      approved = %DraftVersion{review_state: :approved, published: false}
      assert StateMachine.can_publish?(msg, approved)

      refute StateMachine.can_publish?(msg, %DraftVersion{
               review_state: :pending,
               published: false
             })

      refute StateMachine.can_publish?(%AlertMessage{workflow_state: :drafting}, approved)

      refute StateMachine.can_publish?(msg, %DraftVersion{
               review_state: :approved,
               published: true
             })
    end

    test "can_review? requires in_review message + version under review" do
      msg = %AlertMessage{workflow_state: :in_review}
      assert StateMachine.can_review?(msg, %DraftVersion{review_state: :in_review})
      refute StateMachine.can_review?(msg, %DraftVersion{review_state: :pending})

      refute StateMachine.can_review?(%AlertMessage{workflow_state: :drafting}, %DraftVersion{
               review_state: :in_review
             })
    end

    test "can_derive? only from published" do
      assert StateMachine.can_derive?(%AlertMessage{workflow_state: :published})
      refute StateMachine.can_derive?(%AlertMessage{workflow_state: :drafting})
    end
  end
end
