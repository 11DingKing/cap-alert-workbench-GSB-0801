defmodule CapAlertWorkbenchWeb.Api.AlertController do
  use CapAlertWorkbenchWeb, :controller

  alias CapAlertWorkbench.Cap

  def index(conn, _params) do
    alerts = Cap.list_alerts()
    json(conn, %{data: Enum.map(alerts, &serialize_alert_summary/1)})
  end

  def show(conn, %{"id" => id}) do
    with {:ok, alert} <- Cap.fetch_alert(id) do
      versions = Cap.list_versions(alert.id)
      json(conn, %{data: serialize_alert(alert, versions)})
    end
  end

  def create(conn, params) do
    attrs = map_params(params)

    case Cap.create_alert(attrs) do
      {:ok, %{alert: alert}} ->
        conn
        |> put_status(:created)
        |> json(%{data: serialize_alert(alert, Cap.list_versions(alert.id))})

      {:error, changeset} ->
        conn |> put_status(:unprocessable_entity) |> json(%{errors: errors(changeset)})
    end
  end

  def update_draft(conn, %{"id" => id} = params) do
    expected = parse_int(params["expected_lock_version"])
    actor = params["actor"]

    attrs =
      params
      |> Map.drop(["id", "expected_lock_version", "actor"])
      |> map_params()

    case Cap.update_draft(id, expected, attrs, actor) do
      {:ok, %{alert: alert}} ->
        json(conn, %{data: serialize_alert(alert, Cap.list_versions(alert.id))})

      {:error, {:lock_version_mismatch, current, sent}} ->
        conn
        |> put_status(:conflict)
        |> json(%{error: "lock_version_mismatch", current: current, provided: sent})

      {:error, reason} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: inspect(reason)})
    end
  end

  def submit(conn, %{"id" => id} = params) do
    case Cap.submit_for_review(id, params["actor"]) do
      {:ok, %{alert: alert}} -> json(conn, %{data: serialize_alert(alert, Cap.list_versions(alert.id))})
      {:error, reason} -> conn |> put_status(:conflict) |> json(%{error: inspect(reason)})
    end
  end

  def review(conn, %{"id" => id} = params) do
    review_params = %{
      "decision" => params["decision"],
      "comment" => params["comment"]
    }

    case Cap.decide_review(id, review_params, params["actor"]) do
      {:ok, %{alert: alert}} -> json(conn, %{data: serialize_alert(alert, Cap.list_versions(alert.id))})
      {:error, {:stale_review, old, new}} ->
        conn
        |> put_status(:conflict)
        |> json(%{error: "stale_review", decision_revision: old, current_revision: new})
      {:error, reason} -> conn |> put_status(:unprocessable_entity) |> json(%{error: inspect(reason)})
    end
  end

  def publish(conn, %{"id" => id} = params) do
    case Cap.publish(id, params["actor"]) do
      {:ok, %{alert: alert}} -> json(conn, %{data: serialize_alert(alert, Cap.list_versions(alert.id))})
      {:error, :already_published} ->
        conn |> put_status(:conflict) |> json(%{error: "already_published"})
      {:error, reason} -> conn |> put_status(:conflict) |> json(%{error: inspect(reason)})
    end
  end

  def correct(conn, %{"id" => id} = params) do
    attrs = Map.take(params, ["headline", "description", "instruction", "note"])

    case Cap.create_correction(id, attrs, params["actor"]) do
      {:ok, %{alert: alert}} -> json(conn, %{data: serialize_alert(alert, Cap.list_versions(alert.id))})
      {:error, reason} -> conn |> put_status(:unprocessable_entity) |> json(%{error: inspect(reason)})
    end
  end

  def cancel(conn, %{"id" => id} = params) do
    case Cap.create_cancellation(id, %{"note" => params["note"]}, params["actor"]) do
      {:ok, %{alert: alert}} -> json(conn, %{data: serialize_alert(alert, Cap.list_versions(alert.id))})
      {:error, reason} -> conn |> put_status(:unprocessable_entity) |> json(%{error: inspect(reason)})
    end
  end

  def versions(conn, %{"id" => id}) do
    json(conn, %{data: Enum.map(Cap.list_versions(id), &serialize_version/1)})
  end

  def version_xml(conn, %{"id" => id, "version" => version_num}) do
    case Cap.version_xml(id, version_num) do
      {:ok, xml} ->
        conn
        |> put_resp_content_type("application/xml")
        |> send_resp(200, xml)

      {:error, reason} ->
        conn |> put_status(:not_found) |> json(%{error: inspect(reason)})
    end
  end

  def audit(conn, %{"id" => id}) do
    json(conn, %{data: Enum.map(Cap.list_audit_events(id), &serialize_audit/1)})
  end

  def import_xml(conn, %{"xml" => xml}) do
    case Cap.import_xml(xml, conn.assigns[:actor]) do
      {:ok, %{alert: alert}} ->
        conn
        |> put_status(:created)
        |> json(%{data: serialize_alert(alert, Cap.list_versions(alert.id))})

      {:error, reason} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: inspect(reason)})
    end
  end

  defp map_params(params) do
    params
    |> Enum.reject(fn {k, _} -> k in ["id"] end)
    |> Enum.map(fn {k, v} -> {String.to_existing_atom(k), v} end)
    |> Map.new()
  rescue
    ArgumentError ->
      params
      |> Enum.reject(fn {k, _} -> k in ["id"] end)
      |> Enum.map(fn {k, v} -> {String.to_atom(k), v} end)
      |> Map.new()
  end

  defp parse_int(nil), do: nil
  defp parse_int(s) when is_binary(s), do: String.to_integer(s)
  defp parse_int(i) when is_integer(i), do: i

  defp serialize_alert_summary(alert) do
    %{
      id: alert.id,
      identifier: alert.identifier,
      sender: alert.sender,
      status: alert.status,
      latest_published_version: alert.latest_published_version,
      draft_lock_version: alert.draft_lock_version,
      draft_revision: alert.draft_revision,
      last_activity_at: alert.last_activity_at
    }
  end

  defp serialize_alert(alert, versions) do
    serialize_alert_summary(alert)
    |> Map.merge(%{
      draft_payload: alert.draft_payload,
      published_identifier: alert.published_identifier,
      versions: Enum.map(versions, &serialize_version/1),
      inserted_at: alert.inserted_at,
      updated_at: alert.updated_at
    })
  end

  defp serialize_version(version) do
    %{
      id: version.id,
      version_number: version.version_number,
      status: version.status,
      kind: version.kind,
      payload: version.payload,
      references: version.references,
      published_at: version.published_at,
      created_by: version.created_by,
      review_note: version.review_note,
      revision_seed: version.revision_seed,
      inserted_at: version.inserted_at
    }
  end

  defp serialize_audit(event) do
    %{
      id: event.id,
      action: event.action,
      actor: event.actor,
      summary: event.summary,
      metadata: event.metadata,
      occurred_at: event.occurred_at
    }
  end

  defp errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
