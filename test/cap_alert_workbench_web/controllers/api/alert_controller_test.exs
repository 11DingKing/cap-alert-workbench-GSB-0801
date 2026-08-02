defmodule CapAlertWorkbenchWeb.API.AlertControllerTest do
  use CapAlertWorkbenchWeb.ConnCase, async: false

  alias CapAlertWorkbench.CapAlert

  @identifier "CN-API-001"

  @attrs %{
    "identifier" => @identifier,
    "sender" => "api-sender",
    "sent" => ~U[2026-07-29 08:00:00Z],
    "status" => "actual",
    "msg_type" => "alert",
    "scope" => "public",
    "infos" => %{
      "0" => %{
        "language" => "zh-CN",
        "event" => "暴雨",
        "headline" => "API 测试预警",
        "instruction" => "注意安全",
        "urgency" => "immediate",
        "severity" => "severe",
        "certainty" => "likely",
        "geocodes" => %{"0" => %{"value_name" => "Same", "value" => "440800"}}
      }
    }
  }

  setup do
    {:ok, %{alert: alert, version: version}} = CapAlert.create_alert(@attrs, "api-test")
    {:ok, alert: alert, version: version}
  end

  test "GET /api/alerts lists alerts", %{conn: conn} do
    conn = get(conn, ~p"/api/alerts")
    body = json_response(conn, 200)
    assert is_list(body["data"])
    assert Enum.any?(body["data"], &(&1["identifier"] == @identifier))
  end

  test "GET /api/alerts/:identifier returns detail with infos", %{conn: conn} do
    conn = get(conn, ~p"/api/alerts/#{@identifier}")
    body = json_response(conn, 200)
    assert body["data"]["alert"]["identifier"] == @identifier
    assert length(body["data"]["versions"]) == 1
    latest = body["data"]["latest_version"]
    assert length(latest["infos"]) == 1
    assert hd(latest["infos"])["severity"] == "severe"
  end

  test "workflow through API: submit -> review -> publish", %{conn: conn, version: version} do
    conn = post(conn, ~p"/api/alerts/#{@identifier}/versions/#{version.id}/submit")
    assert %{"data" => %{"workflow_state" => "in_review"}} = json_response(conn, 200)

    conn =
      post(conn, ~p"/api/alerts/#{@identifier}/versions/#{version.id}/review", %{
        "decision" => "approve",
        "comment" => "ok"
      })

    assert %{"data" => %{"workflow_state" => "approved"}} = json_response(conn, 200)

    conn = post(conn, ~p"/api/alerts/#{@identifier}/versions/#{version.id}/publish")
    body = json_response(conn, 200)
    assert body["data"]["workflow_state"] == "published"
    assert body["data"]["xml_payload"] =~ ~s(alert xmlns="urn:oasis:names:tc:emergency:cap:1.2")
  end

  test "GET /api/alerts/:identifier/versions/:id/cap returns XML", %{conn: conn, version: version} do
    conn = get(conn, ~p"/api/alerts/#{@identifier}/versions/#{version.id}/cap")
    assert conn.status == 200
    assert [content_type] = get_resp_header(conn, "content-type")
    assert content_type =~ "application/xml"
    xml = response(conn, 200)
    assert xml =~ "CN-API-001"
    assert xml =~ "<status>"
    assert xml =~ "Actual"
    assert xml =~ "<info>"
  end

  test "POST /api/alerts/:identifier/c1 creates a C1 correction alert", %{
    conn: conn,
    version: version
  } do
    {:ok, _} = CapAlert.submit_for_review(version, "api")
    {:ok, approved} = CapAlert.review(version, :approve, "", "api")
    {:ok, _published} = CapAlert.publish(approved, "api")

    conn = post(conn, ~p"/api/alerts/#{@identifier}/c1")
    body = json_response(conn, 201)
    assert body["data"]["alert"]["identifier"] == "#{@identifier}-C1"
    c1_version = body["data"]["version"]
    assert c1_version["msg_type"] == "update"
    assert length(c1_version["infos"]) == 1
    assert hd(c1_version["infos"])["severity"] == "severe"
  end

  test "POST /api/import rejects XXE documents", %{conn: conn} do
    xml =
      ~s(<?xml version="1.0"?><!DOCTYPE foo [<!ENTITY xxe SYSTEM "file:///etc/passwd">]>) <>
        ~s(<alert xmlns="urn:oasis:names:tc:emergency:cap:1.2"><identifier>x</identifier></alert>)

    conn = post(conn, ~p"/api/import", %{"xml" => xml})
    assert %{"error" => _} = json_response(conn, 400)
  end

  test "404 for missing alert", %{conn: conn} do
    conn = get(conn, ~p"/api/alerts/NOPE")
    assert json_response(conn, 404)
  end
end
