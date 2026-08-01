defmodule CapAlertWorkbenchWeb.Api.MessageController do
  @moduledoc "预警编审 REST API。所有写操作只调用 Alerts 公开用例。"
  use CapAlertWorkbenchWeb, :controller

  alias CapAlertWorkbench.Alerts
  alias CapAlertWorkbench.Cap.Lifecycle

  action_fallback CapAlertWorkbenchWeb.Api.FallbackController

  def index(conn, _params) do
    streams =
      Alerts.list_streams()
      |> Enum.map(fn stream ->
        %{
          id: stream.id,
          identifier: stream.identifier,
          sender: stream.sender,
          state: stream.state,
          versions:
            Enum.map(stream.versions, fn v ->
              %{
                id: v.id,
                version_number: v.version_number,
                workflow: v.workflow,
                msg_type: v.msg_type,
                lock_version: v.lock_version
              }
            end)
        }
      end)

    json(conn, %{data: streams})
  end

  def show(conn, %{"id" => id}) do
    with {:ok, detail} <- Alerts.get_stream_detail(id) do
      json(conn, %{
        data: %{
          id: detail.stream.id,
          identifier: detail.stream.identifier,
          sender: detail.stream.sender,
          state: detail.stream.state,
          versions: Enum.map(detail.versions, &version_json/1),
          published_documents:
            Enum.map(detail.published_documents, fn p ->
              %{
                id: p.id,
                version_id: p.version_id,
                identifier: p.identifier,
                msg_type: p.msg_type,
                sent_at: p.sent_at
              }
            end),
          audit_events:
            Enum.map(detail.audit_events, fn a ->
              %{id: a.id, event: a.event, actor: a.actor, at: a.inserted_at, details: a.details}
            end),
          outbox_events:
            Enum.map(detail.outbox_events, fn o ->
              %{id: o.id, type: o.type, status: o.status, at: o.inserted_at}
            end)
        }
      })
    end
  end

  def update_draft(conn, %{"id" => id, "lock_version" => lock} = params) do
    actor = Map.get(params, "actor", "api")
    draft = Map.get(params, "draft", params)

    with {:ok, version} <- Alerts.get_version(id),
         {:ok, payload} <- Alerts.compose_payload(version, stringify_keys(draft)),
         {:ok, updated} <-
           Alerts.update_draft(id, %{payload: payload}, to_integer(lock), actor) do
      json(conn, %{data: version_json(updated)})
    end
  end

  def submit_review(conn, %{"id" => id, "lock_version" => lock} = params) do
    actor = Map.get(params, "actor", "api")

    with {:ok, updated} <- Alerts.submit_for_review(id, to_integer(lock), actor) do
      json(conn, %{data: version_json(updated)})
    end
  end

  def review(conn, %{"id" => id, "decision" => decision, "pinned_lock_version" => pin} = params) do
    reviewer = Map.get(params, "reviewer", "api-reviewer")
    note = Map.get(params, "note")

    with {:ok, decision} <- parse_decision(decision),
         {:ok, updated} <- Alerts.decide_review(id, decision, note, reviewer, to_integer(pin)) do
      json(conn, %{data: version_json(updated)})
    end
  end

  def publish(conn, %{"id" => id} = params) do
    actor = Map.get(params, "actor", "api")

    with {:ok, published} <- Alerts.publish(id, actor) do
      json(conn, %{
        data: %{id: published.id, identifier: published.identifier, sent_at: published.sent_at}
      })
    end
  end

  def start_correction(conn, %{"id" => id} = params) do
    actor = Map.get(params, "actor", "api")

    with {:ok, version} <- Alerts.start_correction(id, actor) do
      conn |> put_status(:created) |> json(%{data: version_json(version)})
    end
  end

  def start_cancellation(conn, %{"id" => id} = params) do
    actor = Map.get(params, "actor", "api")

    with {:ok, version} <- Alerts.start_cancellation(id, actor) do
      conn |> put_status(:created) |> json(%{data: version_json(version)})
    end
  end

  def export_xml(conn, %{"id" => id}) do
    with {:ok, xml} <- Alerts.export_cap_xml(id) do
      conn
      |> put_resp_content_type("application/xml")
      |> send_resp(200, xml)
    end
  end

  def import_xml(conn, _params) do
    with {:ok, body, conn} <- Plug.Conn.read_body(conn),
         {:ok, %{stream: stream, version: version}} <-
           Alerts.import_cap_xml(body, "api-import") do
      conn
      |> put_status(:created)
      |> json(%{data: %{stream_id: stream.id, version: version_json(version)}})
    end
  end

  defp version_json(version) do
    %{
      id: version.id,
      stream_id: version.stream_id,
      version_number: version.version_number,
      workflow: version.workflow,
      msg_type: version.msg_type,
      lock_version: version.lock_version,
      payload: version.payload,
      editable: Lifecycle.editable?(version.workflow)
    }
  end

  defp parse_decision("approved"), do: {:ok, :approved}
  defp parse_decision("rejected"), do: {:ok, :rejected}
  defp parse_decision(_other), do: {:error, :invalid_decision}

  defp to_integer(value) when is_integer(value), do: value
  defp to_integer(value) when is_binary(value), do: String.to_integer(value)

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end
end
