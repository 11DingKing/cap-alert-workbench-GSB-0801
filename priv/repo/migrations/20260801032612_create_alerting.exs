defmodule CapAlertWorkbench.Repo.Migrations.CreateAlerting do
  use Ecto.Migration

  def change do
    # ------------------------------------------------------------------
    # 消息流：一条预警（稳定标识）从起草到发布/更正/解除的聚合根
    # ------------------------------------------------------------------
    create table(:alert_streams) do
      # 业务标识，全局稳定且唯一，如 CN-20260729-GD-RAIN-001
      add :identifier, :string, null: false
      add :sender, :string, null: false
      # stream 状态机：drafting | published | cancelled
      add :state, :string, null: false, default: "drafting"

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:alert_streams, [:identifier])

    # ------------------------------------------------------------------
    # 版本：内容不可变快照 + 乐观锁 + 工作流状态
    # ------------------------------------------------------------------
    create table(:alert_versions) do
      add :stream_id, references(:alert_streams, on_delete: :delete_all), null: false
      add :version_number, :integer, null: false
      # 版本工作流状态机：editing | in_review | approved | published
      add :workflow, :string, null: false, default: "editing"
      # CAP msgType：alert | update | cancel
      add :msg_type, :string, null: false, default: "alert"
      # 结构化 CAP 文档（含未知扩展字段），jsonb 存储
      add :payload, :map, null: false
      # 乐观锁
      add :lock_version, :integer, null: false, default: 1
      # 编辑者（最近保存人）
      add :edited_by, :string

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:alert_versions, [:stream_id, :version_number])

    # 同一消息流同一时间只允许一个未发布草稿（editing/in_review/approved）
    create unique_index(
             :alert_versions,
             [:stream_id],
             name: :alert_versions_single_active_draft,
             where: "workflow IN ('editing', 'in_review', 'approved')"
           )

    # ------------------------------------------------------------------
    # 复核结论：钉住复核时的 lock_version，防止旧结论套到新草稿上
    # ------------------------------------------------------------------
    create table(:review_decisions) do
      add :version_id, references(:alert_versions, on_delete: :delete_all), null: false
      add :decision, :string, null: false
      add :reviewer, :string, null: false
      add :note, :string
      add :pinned_lock_version, :integer, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:review_decisions, [:version_id])

    # ------------------------------------------------------------------
    # 已发布文档：不可变，CAP XML 冻结快照
    # ------------------------------------------------------------------
    create table(:published_documents) do
      add :stream_id, references(:alert_streams, on_delete: :restrict), null: false
      add :version_id, references(:alert_versions, on_delete: :restrict), null: false
      add :identifier, :string, null: false
      add :msg_type, :string, null: false
      add :cap_xml, :text, null: false
      add :sent_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:published_documents, [:version_id])
    create index(:published_documents, [:stream_id])

    # ------------------------------------------------------------------
    # 审计事件：与状态变更同事务写入
    # ------------------------------------------------------------------
    create table(:audit_events) do
      add :stream_id, references(:alert_streams, on_delete: :delete_all), null: false
      add :version_id, references(:alert_versions, on_delete: :delete_all)
      add :event, :string, null: false
      add :actor, :string, null: false
      add :details, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:audit_events, [:stream_id])

    # ------------------------------------------------------------------
    # 通知 outbox：与发布同事务写入，保证不丢不重
    # ------------------------------------------------------------------
    create table(:outbox_events) do
      add :stream_id, references(:alert_streams, on_delete: :delete_all), null: false
      add :version_id, references(:alert_versions, on_delete: :delete_all), null: false
      add :type, :string, null: false
      add :payload, :map, null: false
      add :status, :string, null: false, default: "pending"

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:outbox_events, [:status])
  end
end
