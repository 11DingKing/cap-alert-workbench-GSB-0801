defmodule CapAlertWorkbenchWeb.Api.FallbackController do
  @moduledoc "API 错误映射：所有错误以机器可读 code 返回 JSON。"
  use CapAlertWorkbenchWeb, :controller

  def call(conn, {:error, :not_found}) do
    error(conn, :not_found, "not_found", "资源不存在")
  end

  def call(conn, {:error, :stale_lock}) do
    error(conn, :conflict, "stale_lock", "草稿已被他人修改，请刷新后重试")
  end

  def call(conn, {:error, :stale_review}) do
    error(conn, :conflict, "stale_review", "复核结论已过时：草稿在复核期间被修改")
  end

  def call(conn, {:error, :already_published}) do
    error(conn, :conflict, "already_published", "该版本已发布，禁止重复发布")
  end

  def call(conn, {:error, {:not_publishable, workflow}}) do
    error(conn, :conflict, "not_publishable", "当前状态不可发布: #{workflow}")
  end

  def call(conn, {:error, :not_latest_version}) do
    error(conn, :conflict, "not_latest_version", "只有最新草稿版本可以发布")
  end

  def call(conn, {:error, :draft_already_exists}) do
    error(conn, :conflict, "draft_already_exists", "已存在未发布草稿，请先处理")
  end

  def call(conn, {:error, :identifier_taken}) do
    error(conn, :conflict, "identifier_taken", "消息标识已存在")
  end

  def call(conn, {:error, {:invalid_transition, from, event}}) do
    error(conn, :unprocessable_entity, "invalid_transition", "非法状态转换: #{from} + #{event}")
  end

  def call(conn, {:error, :invalid_decision}) do
    error(conn, :unprocessable_entity, "invalid_decision", "复核结论必须是 approved 或 rejected")
  end

  def call(conn, {:error, :doctype_forbidden}) do
    error(conn, :unprocessable_entity, "doctype_forbidden", "禁止包含 DOCTYPE/实体声明的 XML")
  end

  def call(conn, {:error, {:malformed_xml, message}}) do
    error(conn, :unprocessable_entity, "malformed_xml", "XML 解析失败: #{message}")
  end

  def call(conn, {:error, {:unknown_enum, kind, value}}) do
    error(conn, :unprocessable_entity, "unknown_enum", "未知枚举值 #{kind}: #{value}")
  end

  def call(conn, {:error, {:unexpected_root, name}}) do
    error(conn, :unprocessable_entity, "unexpected_root", "根元素必须是 alert，实际: #{name}")
  end

  def call(conn, {:error, {:missing_element, name}}) do
    error(conn, :unprocessable_entity, "missing_element", "缺少必需元素: #{name}")
  end

  def call(conn, {:error, errors}) when is_list(errors) do
    message = Enum.map_join(errors, "; ", fn {field, msg} -> "#{field} #{msg}" end)
    error(conn, :unprocessable_entity, "validation_failed", message)
  end

  def call(conn, {:error, %Ecto.Changeset{} = changeset}) do
    message =
      Ecto.Changeset.traverse_errors(changeset, fn {msg, _opts} -> msg end)
      |> Enum.map_join("; ", fn {field, msgs} -> "#{field} #{Enum.join(msgs, ",")}" end)

    error(conn, :unprocessable_entity, "changeset_failed", message)
  end

  def call(conn, {:error, other}) do
    error(conn, :unprocessable_entity, "error", inspect(other))
  end

  defp error(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{error: %{code: code, message: message}})
  end
end
