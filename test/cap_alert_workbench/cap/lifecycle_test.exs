defmodule CapAlertWorkbench.Cap.LifecycleTest do
  use ExUnit.Case, async: true

  alias CapAlertWorkbench.Cap.Lifecycle

  test "草稿工作流合法转换" do
    assert {:ok, :in_review} = Lifecycle.transition_draft(:editing, :submit_review)
    assert {:ok, :in_review} = Lifecycle.transition_draft(:in_review, :revise)
    assert {:ok, :approved} = Lifecycle.transition_draft(:in_review, :approve)
    assert {:ok, :editing} = Lifecycle.transition_draft(:in_review, :reject)
    assert {:ok, :published} = Lifecycle.transition_draft(:approved, :publish)
  end

  test "草稿工作流非法转换全部显式拒绝" do
    assert {:error, {:invalid_transition, :editing, :publish}} =
             Lifecycle.transition_draft(:editing, :publish)

    assert {:error, {:invalid_transition, :editing, :approve}} =
             Lifecycle.transition_draft(:editing, :approve)

    assert {:error, {:invalid_transition, :published, :revise}} =
             Lifecycle.transition_draft(:published, :revise)

    assert {:error, {:invalid_transition, :published, :reject}} =
             Lifecycle.transition_draft(:published, :reject)
  end

  test "消息流工作流转换" do
    assert {:ok, :published} = Lifecycle.transition_stream(:drafting, :publish)
    assert {:ok, :published} = Lifecycle.transition_stream(:published, :publish)
    assert {:ok, :cancelled} = Lifecycle.transition_stream(:published, :publish_cancel)

    assert {:error, {:invalid_transition, :cancelled, :publish}} =
             Lifecycle.transition_stream(:cancelled, :publish)

    assert {:error, {:invalid_transition, :drafting, :publish_cancel}} =
             Lifecycle.transition_stream(:drafting, :publish_cancel)
  end

  test "可编辑状态判定" do
    assert Lifecycle.editable?(:editing)
    assert Lifecycle.editable?(:in_review)
    refute Lifecycle.editable?(:approved)
    refute Lifecycle.editable?(:published)
  end
end
