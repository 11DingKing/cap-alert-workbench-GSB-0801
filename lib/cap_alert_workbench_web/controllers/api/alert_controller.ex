defmodule CapAlertWorkbenchWeb.API.AlertController do
  use CapAlertWorkbenchWeb, :controller

  alias CapAlertWorkbench.CapAlert
  alias CapAlertWorkbench.CapAlert.AlertVersion

  action_fallback CapAlertWorkbenchWeb.FallbackController

  def index(conn, _params) do
    alerts = CapAlert.list_alerts()
    json(conn, %{data: Enum.map(alerts, &alert_json/1)})
  end

  def create(conn, params) do
    actor = actor(conn)

    case CapAlert.create_alert(params, actor) do
      {:ok, %{alert: alert, version: version}} ->
        conn
        |> put_status(:created)
        |> json(%{data: Map.merge(alert_json(alert), %{latest_version: version_json(version)})})

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  def show(conn, %{"identifier" => identifier}) do
    case CapAlert.load_alert(identifier) do
      nil ->
        {:error, :not_found}

      data ->
        json(conn, %{
          data: %{
            alert: alert_json(data.alert),
            latest_version: data.latest_version && version_json(data.latest_version),
            published_version: data.published_version && version_json(data.published_version),
            versions: Enum.map(data.versions, &version_json/1),
            audit_events: Enum.map(data.audit_events, &audit_json/1),
            outbox: Enum.map(data.outbox, &outbox_json/1)
          }
        })
    end
  end

  def versions(conn, %{"identifier" => identifier}) do
    if CapAlert.get_alert(identifier) do
      versions = CapAlert.list_versions(identifier)
      json(conn, %{data: Enum.map(versions, &version_json/1)})
    else
      {:error, :not_found}
    end
  end

  def version(conn, %{"id" => id}) do
    case CapAlert.get_version(id) do
      nil -> {:error, :not_found}
      version -> json(conn, %{data: version_json(version)})
    end
  end

  def export_cap(conn, %{"id" => id}) do
    case CapAlert.get_version(id) do
      nil ->
        {:error, :not_found}

      version ->
        xml = CapAlert.export_cap(version)

        conn
        |> put_resp_content_type("application/xml", "utf-8")
        |> send_resp(200, xml)
    end
  end

  def submit(conn, %{"id" => id}) do
    transition(conn, id, fn version -> CapAlert.submit_for_review(version, actor(conn)) end)
  end

  def review(conn, %{"id" => id} = params) do
    decision = parse_decision(params["decision"])
    comment = params["comment"]

    if decision in [:approve, :reject] do
      transition(conn, id, fn version ->
        CapAlert.review(version, decision, comment, actor(conn))
      end)
    else
      {:error, :invalid_decision}
    end
  end

  def publish(conn, %{"id" => id}) do
    transition(conn, id, fn version -> CapAlert.publish(version, actor(conn)) end)
  end

  def create_correction(conn, %{"identifier" => identifier} = params) do
    create_followup(conn, identifier, params, :correction)
  end

  def create_cancellation(conn, %{"identifier" => identifier} = params) do
    create_followup(conn, identifier, params, :cancellation)
  end

  def create_c1(conn, %{"identifier" => identifier} = params) do
    attrs =
      params
      |> Map.drop(["identifier"])
      |> Map.put("source_identifier", identifier)

    case CapAlert.create_correction_alert(attrs, actor(conn)) do
      {:ok, %{alert: alert, version: version}} ->
        conn
        |> put_status(:created)
        |> json(%{
          data: %{
            alert: alert_json(alert),
            version: version_json(version)
          }
        })

      {:error, reason} ->
        {:error, reason}
    end
  end

  def create_c2(conn, %{"identifier" => identifier} = params) do
    attrs =
      params
      |> Map.drop(["identifier"])
      |> Map.put("source_identifier", identifier)

    case CapAlert.create_cancellation_alert(attrs, actor(conn)) do
      {:ok, %{alert: alert, version: version}} ->
        conn
        |> put_status(:created)
        |> json(%{
          data: %{
            alert: alert_json(alert),
            version: version_json(version)
          }
        })

      {:error, reason} ->
        {:error, reason}
    end
  end

  def import(conn, %{"xml" => xml}) do
    case CapAlert.import_cap(xml, actor(conn)) do
      {:ok, result} ->
        conn
        |> put_status(:created)
        |> json(%{
          data: %{
            alert: alert_json(result.alert),
            version: version_json(result.version)
          }
        })

      {:error, reason} ->
        {:error, reason}
    end
  end

  def import(_conn, _params) do
    {:error, :missing_xml}
  end

  defp transition(conn, id, fun) do
    case CapAlert.get_version(id) do
      nil ->
        {:error, :not_found}

      version ->
        case fun.(version) do
          {:ok, updated} -> json(conn, %{data: version_json(updated)})
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp create_followup(conn, identifier, params, kind) do
    attrs =
      params
      |> Map.drop(["identifier"])
      |> Map.put("alert_identifier", identifier)

    result =
      case kind do
        :correction -> CapAlert.create_correction(attrs, actor(conn))
        :cancellation -> CapAlert.create_cancellation(attrs, actor(conn))
      end

    case result do
      {:ok, version} ->
        conn |> put_status(:created) |> json(%{data: version_json(version)})

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp actor(conn) do
    get_req_header(conn, "x-actor") |> List.first() || "api"
  end

  defp parse_decision("approve"), do: :approve
  defp parse_decision("reject"), do: :reject
  defp parse_decision(:approve), do: :approve
  defp parse_decision(:reject), do: :reject
  defp parse_decision(_), do: nil

  # ---------------------------------------------------------------------------
  # JSON serialization
  # ---------------------------------------------------------------------------

  defp alert_json(alert) do
    %{
      identifier: alert.identifier,
      sender: alert.sender,
      state: alert.state,
      latest_version_id: alert.latest_version_id,
      published_version_id: alert.published_version_id,
      inserted_at: alert.inserted_at,
      updated_at: alert.updated_at
    }
  end

  defp version_json(%AlertVersion{} = v) do
    %{
      id: v.id,
      alert_identifier: v.alert_identifier,
      version_number: v.version_number,
      lock_version: v.lock_version,
      sender: v.sender,
      sent: v.sent,
      status: v.status,
      msg_type: v.msg_type,
      scope: v.scope,
      references: v.references,
      infos: Enum.map(v.infos, &info_json/1),
      workflow_state: v.workflow_state,
      review_comment: v.review_comment,
      reviewed_by: v.reviewed_by,
      reviewed_at: v.reviewed_at,
      published_at: v.published_at,
      based_on_version_id: v.based_on_version_id,
      xml_payload: v.xml_payload,
      inserted_at: v.inserted_at,
      updated_at: v.updated_at
    }
  end

  defp info_json(info) do
    %{
      language: info.language,
      event: info.event,
      urgency: info.urgency,
      severity: info.severity,
      certainty: info.certainty,
      headline: info.headline,
      description: info.description,
      instruction: info.instruction,
      area_desc: info.area_desc,
      geocodes: Enum.map(info.geocodes, &%{value_name: &1.value_name, value: &1.value})
    }
  end

  defp audit_json(a) do
    %{
      id: a.id,
      version_id: a.version_id,
      actor: a.actor,
      action: a.action,
      details: a.details,
      inserted_at: a.inserted_at
    }
  end

  defp outbox_json(o) do
    %{
      id: o.id,
      event_type: o.event_type,
      status: o.status,
      attempts: o.attempts,
      payload: o.payload,
      published_at: o.published_at,
      inserted_at: o.inserted_at
    }
  end
end
