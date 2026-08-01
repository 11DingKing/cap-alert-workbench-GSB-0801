defmodule CapAlertWorkbench.Alerts.Version do
  @moduledoc """
  预警草稿/发布版本。内容一经写入即不可变快照；编辑通过乐观锁
  （`lock_version`）保护，工作流状态只允许经状态机转换。
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias CapAlertWorkbench.Cap.Lifecycle

  schema "alert_versions" do
    field :version_number, :integer
    field :workflow, Ecto.Enum, values: Lifecycle.draft_states(), default: :editing
    field :msg_type, Ecto.Enum, values: [:alert, :update, :cancel], default: :alert
    field :payload, :map
    field :edited_by, :string

    # 乐观锁字段：每次成功更新自动 +1，陈旧提交触发 stale 错误
    field :lock_version, :integer, default: 1

    belongs_to :stream, CapAlertWorkbench.Alerts.Stream
    has_many :review_decisions, CapAlertWorkbench.Alerts.ReviewDecision

    timestamps(type: :utc_datetime_usec)
  end

  @doc "新建版本的 changeset（不做乐观锁递增，初始锁号为 1）。"
  def create_changeset(%__MODULE__{} = version, attrs) do
    version
    |> cast(attrs, [:payload, :edited_by])
    |> validate_required([:payload])
  end

  @doc "编辑草稿的 changeset，附带乐观锁检查。"
  def edit_changeset(%__MODULE__{} = version, attrs) do
    changeset =
      version
      |> cast(attrs, [:payload, :edited_by])
      |> validate_required([:payload])
      |> optimistic_lock(:lock_version)

    # 内容未变时 changeset 为空会导致 Ecto 跳过 UPDATE，乐观锁过滤器随之失效；
    # 强制标记变更，保证每次保存都真正执行带锁过滤的 UPDATE。
    force_change(changeset, :edited_by, get_field(changeset, :edited_by))
  end

  @doc "工作流状态转换 changeset（状态由状态机计算，不接受外部直传）。"
  def workflow_changeset(%__MODULE__{} = version, to_state, opts \\ []) do
    version
    |> change(%{workflow: to_state})
    |> maybe_put_edited_by(opts)
  end

  defp maybe_put_edited_by(changeset, opts) do
    case Keyword.get(opts, :edited_by) do
      nil -> changeset
      actor -> put_change(changeset, :edited_by, actor)
    end
  end
end
