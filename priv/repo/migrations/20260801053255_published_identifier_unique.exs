defmodule CapAlertWorkbench.Repo.Migrations.PublishedIdentifierUnique do
  use Ecto.Migration

  def change do
    # 兜底约束：同一 CAP 标识（如 CN-20260729-GD-RAIN-001-C1）最多发布一次，
    # 即使应用层守卫全部失效也不可能产生第二份同标识发布文档。
    create unique_index(:published_documents, [:identifier])
  end
end
