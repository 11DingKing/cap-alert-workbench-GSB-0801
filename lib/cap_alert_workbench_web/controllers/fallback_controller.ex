defmodule CapAlertWorkbenchWeb.FallbackController do
  use CapAlertWorkbenchWeb, :controller

  def call(conn, {:error, %Ecto.Changeset{} = changeset}) do
    conn
    |> put_status(:unprocessable_entity)
    |> put_view(json: CapAlertWorkbenchWeb.ChangesetJSON)
    |> render(:error, changeset: changeset)
  end

  def call(conn, {:error, :not_found}) do
    conn
    |> put_status(:not_found)
    |> json(%{error: "not_found"})
  end

  def call(conn, {:error, reason}) when is_atom(reason) do
    {status, message} = error_reason(reason)

    conn
    |> put_status(status)
    |> json(%{error: message})
  end

  def call(conn, {:error, reason}) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: inspect(reason)})
  end

  defp error_reason(:stale), do: {409, "版本已被他人更新，请刷新后重试（乐观锁冲突）"}
  defp error_reason(:not_editable), do: {409, "当前状态不可编辑"}
  defp error_reason(:not_latest), do: {409, "该版本已不是最新版本"}
  defp error_reason(:not_latest_version), do: {409, "您操作的版本已过期（状态已变更），请刷新后重试，不得覆盖已发布的地区级严重度"}
  defp error_reason(:stale_review), do: {409, "复核结论已过期：已存在更新的草稿"}
  defp error_reason(:not_publishable), do: {409, "只有通过复核的最新版本可以发布"}
  defp error_reason(:already_published), do: {409, "该版本已发布，不可重复发布"}
  defp error_reason(:no_published_version), do: {409, "尚未发布过任何版本"}
  defp error_reason(:invalid_decision), do: {400, "decision 必须为 approve 或 reject"}
  defp error_reason(:missing_xml), do: {400, "缺少 xml 参数"}
  defp error_reason(:missing_identifier), do: {400, "CAP XML 缺少 identifier"}
  defp error_reason(:not_an_alert), do: {400, "XML 不是 CAP alert 文档"}
  defp error_reason(:doctype_or_entity_forbidden), do: {400, "禁止 DOCTYPE/ENTITY 声明"}
  defp error_reason(reason), do: {400, to_string(reason)}
end
