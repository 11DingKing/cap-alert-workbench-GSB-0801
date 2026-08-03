defmodule CapAlertWorkbench.Cap.Lifecycle do
  @moduledoc """
  预警编审工作流状态机（纯函数，位于领域/服务层）。

  草稿版本工作流：

      :editing      --:submit_review--> :in_review
      :in_review    --:revise---------> :in_review   (编辑中改稿，乐观锁版本号递增)
      :in_review    --:approve--------> :approved
      :in_review    --:reject---------> :editing
      :approved     --:publish--------> :published

  消息流（stream）工作流：

      :drafting     --:publish--------> :published
      :published    --:publish--------> :published   (更正发布)
      :published    --:publish_cancel-> :cancelled

  所有转换使用显式枚举与模式匹配，非法转换返回
  `{:error, {:invalid_transition, from, event}}`。
  """

  @draft_states [:editing, :in_review, :approved, :published]
  @stream_states [:drafting, :published, :cancelled]

  @type draft_state :: :editing | :in_review | :approved | :published
  @type stream_state :: :drafting | :published | :cancelled
  @type draft_event :: :submit_review | :revise | :approve | :reject | :publish
  @type stream_event :: :publish | :publish_cancel

  def draft_states, do: @draft_states
  def stream_states, do: @stream_states

  @spec transition_draft(draft_state(), draft_event()) ::
          {:ok, draft_state()} | {:error, {:invalid_transition, draft_state(), draft_event()}}
  def transition_draft(:editing, :submit_review), do: {:ok, :in_review}
  def transition_draft(:in_review, :revise), do: {:ok, :in_review}
  def transition_draft(:in_review, :approve), do: {:ok, :approved}
  def transition_draft(:in_review, :reject), do: {:ok, :editing}
  def transition_draft(:approved, :publish), do: {:ok, :published}

  def transition_draft(from, event) when from in @draft_states,
    do: {:error, {:invalid_transition, from, event}}

  @spec transition_stream(stream_state(), stream_event()) ::
          {:ok, stream_state()} | {:error, {:invalid_transition, stream_state(), stream_event()}}
  def transition_stream(:drafting, :publish), do: {:ok, :published}
  def transition_stream(:published, :publish), do: {:ok, :published}
  def transition_stream(:published, :publish_cancel), do: {:ok, :cancelled}

  def transition_stream(from, event) when from in @stream_states,
    do: {:error, {:invalid_transition, from, event}}

  @doc "该工作流状态下是否允许编辑草稿内容。"
  @spec editable?(draft_state()) :: boolean()
  def editable?(:editing), do: true
  def editable?(:in_review), do: true
  def editable?(:approved), do: false
  def editable?(:published), do: false
end
