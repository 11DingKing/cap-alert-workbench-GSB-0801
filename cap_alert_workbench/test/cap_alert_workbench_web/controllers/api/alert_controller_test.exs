defmodule CapAlertWorkbenchWeb.Api.AlertControllerTest do
  use CapAlertWorkbenchWeb.ConnCase, async: false

  alias CapAlertWorkbench.Cap

  setup do
    message = Cap.Xml.Codec.seed_message()

    attrs =
      message
      |> Map.from_struct()
      |> Map.put(:actor, "test")
      |> Map.to_list()

    {:ok, %{alert: alert}} = Cap.create_alert(attrs)
    %{alert: alert}
  end

  test "GET /api/alerts lists alerts", %{conn: conn} do
    conn = get(conn, ~p"/api/alerts")
    body = json_response(conn, 200)
    assert is_list(body["data"])
    assert length(body["data"]) >= 1
  end

  test "GET /api/alerts/:id returns the alert with versions", %{conn: conn, alert: alert} do
    conn = get(conn, ~p"/api/alerts/#{alert.id}")
    body = json_response(conn, 200)
    assert body["data"]["identifier"] == alert.identifier
    assert body["data"]["status"] == "draft"
  end

  test "PUT /api/alerts/:id/draft enforces optimistic locking", %{conn: conn, alert: alert} do
    # First update succeeds at lock version 1.
    conn =
      put(conn, ~p"/api/alerts/#{alert.id}/draft", %{
        "expected_lock_version" => 1,
        "headline" => "API 更新"
      })

    assert %{"data" => data} = json_response(conn, 200)
    assert data["draft_lock_version"] == 2

    # Second update with stale lock version fails with 409.
    conn =
      build_conn()
      |> put(~p"/api/alerts/#{alert.id}/draft", %{
        "expected_lock_version" => 1,
        "headline" => "陈旧写入"
      })

    assert %{"error" => "lock_version_mismatch"} = json_response(conn, 409)
  end

  test "full review and publish flow via API", %{conn: conn, alert: alert} do
    conn = post(conn, ~p"/api/alerts/#{alert.id}/submit", %{})
    assert %{"data" => %{"status" => "in_review"}} = json_response(conn, 200)

    conn =
      build_conn()
      |> post(~p"/api/alerts/#{alert.id}/review", %{
        "decision" => "approved",
        "comment" => "通过"
      })

    assert %{"data" => %{"status" => "approved"}} = json_response(conn, 200)

    conn = build_conn() |> post(~p"/api/alerts/#{alert.id}/publish", %{})
    assert %{"data" => %{"status" => "published"}} = json_response(conn, 200)

    # Duplicate publish is rejected.
    conn = build_conn() |> post(~p"/api/alerts/#{alert.id}/publish", %{})
    assert json_response(conn, 409)
  end

  test "stale review decisions are rejected via API", %{conn: conn, alert: alert} do
    post(conn, ~p"/api/alerts/#{alert.id}/submit", %{})

    # Edit the draft while in review, invalidating the review revision.
    {:ok, _} = Cap.update_draft(alert.id, 1, %{"headline" => "改了"}, "editor")

    conn =
      build_conn()
      |> post(~p"/api/alerts/#{alert.id}/review", %{"decision" => "approved"})

    assert json_response(conn, 422)
  end

  test "GET /api/alerts/:id/versions/:version/xml returns CAP XML", %{conn: conn, alert: alert} do
    post(build_conn(), ~p"/api/alerts/#{alert.id}/submit", %{})

    build_conn()
    |> post(~p"/api/alerts/#{alert.id}/review", %{"decision" => "approved"})

    build_conn() |> post(~p"/api/alerts/#{alert.id}/publish", %{})

    conn = get(conn, ~p"/api/alerts/#{alert.id}/versions/1/xml")
    assert get_resp_header(conn, "content-type") |> hd() =~ "application/xml"
    assert conn.resp_body =~ "<alert xmlns="
    assert conn.resp_body =~ "CN-20260729-GD-RAIN-001"
  end
end
