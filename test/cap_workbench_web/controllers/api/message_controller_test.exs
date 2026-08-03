defmodule CapWorkbenchWeb.Api.MessageControllerTest do
  use CapWorkbenchWeb.ConnCase

  import CapWorkbench.AlertsFixtures

  alias CapWorkbench.Alerts

  setup %{conn: conn} do
    {:ok, conn: put_req_header(conn, "accept", "application/json")}
  end

  describe "index/show" do
    test "lists and shows messages", %{conn: conn} do
      message = message_fixture()

      conn = get(conn, ~p"/api/messages")
      assert %{"data" => [entry]} = json_response(conn, 200)
      assert entry["identifier"] == message.identifier

      conn = get(conn, ~p"/api/messages/#{message.id}")
      assert %{"data" => full} = json_response(conn, 200)
      assert [_v] = full["versions"]
    end
  end

  describe "workflow endpoints" do
    test "create -> submit -> review -> publish", %{conn: conn} do
      attrs = %{
        "identifier" => "CN-API-#{System.unique_integer([:positive])}",
        "sender" => "cap@gd.gov.cn",
        "sent_at" => "2026-07-29T08:00:00Z",
        "status" => "actual",
        "msg_type" => "alert",
        "scope" => "public",
        "infos" => [
          %{
            "language" => "zh-CN",
            "category" => "met",
            "event" => "暴雨",
            "urgency" => "immediate",
            "severity" => "severe",
            "certainty" => "likely",
            "headline" => "标题",
            "description" => "描述",
            "area_description" => "揭阳、茂名",
            "geocodes" => ["440800", "440900"]
          }
        ]
      }

      conn = post(conn, ~p"/api/messages", %{"message" => attrs})
      assert %{"data" => created} = json_response(conn, 201)
      id = created["id"]
      assert created["workflow_state"] == "drafting"

      conn = recycle(conn) |> put_req_header("accept", "application/json")

      conn =
        post(conn, ~p"/api/messages/#{id}/submit", %{"lock_version" => created["lock_version"]})

      assert %{"data" => submitted} = json_response(conn, 200)
      assert submitted["workflow_state"] == "in_review"

      conn = recycle(conn) |> put_req_header("accept", "application/json")

      conn =
        post(conn, ~p"/api/messages/#{id}/review", %{
          "decision" => "approve",
          "lock_version" => submitted["lock_version"]
        })

      assert %{"data" => approved} = json_response(conn, 200)

      conn = recycle(conn) |> put_req_header("accept", "application/json")

      conn =
        post(conn, ~p"/api/messages/#{id}/publish", %{"lock_version" => approved["lock_version"]})

      assert %{"data" => published} = json_response(conn, 200)
      assert published["workflow_state"] == "published"
      assert [%{"infos" => [%{"severity" => "severe"}]} | _] = published["versions"]
    end

    test "per-region correction via API splits 440900 to Extreme", %{conn: conn} do
      published = published_message_fixture()

      conn =
        post(conn, ~p"/api/messages/#{published.id}/correction", %{
          "overrides" => %{"region_severities" => %{"440900" => "extreme"}}
        })

      assert %{"data" => correction} = json_response(conn, 201)
      assert correction["identifier"] == published.identifier <> "-C1"

      severities =
        correction["versions"]
        |> List.first()
        |> Map.get("infos")
        |> Enum.flat_map(fn info -> Enum.map(info["geocodes"], &{&1, info["severity"]}) end)
        |> Map.new()

      assert severities["440800"] == "severe"
      assert severities["440900"] == "extreme"
    end

    test "duplicate publish returns 409 conflict", %{conn: conn} do
      message = published_message_fixture()

      conn =
        post(conn, ~p"/api/messages/#{message.id}/publish", %{
          "lock_version" => message.lock_version
        })

      assert %{"error" => %{"code" => "already_published"}} = json_response(conn, 409)
    end

    test "stale lock version returns 409 conflict on save", %{conn: conn} do
      message = message_fixture()
      stale = message.lock_version
      info_map = CapWorkbench.Alerts.info_to_map(hd(Alerts.latest_version(message).infos))
      {:ok, _} = Alerts.save_new_version(message, %{"infos" => [info_map]}, stale)

      conn =
        post(conn, ~p"/api/messages/#{message.id}/versions", %{
          "version" => %{"infos" => [%{"headline" => "后手"}]},
          "lock_version" => stale
        })

      assert %{"error" => %{"code" => "stale"}} = json_response(conn, 409)
    end
  end

  describe "XML import/export" do
    test "export returns CAP XML", %{conn: conn} do
      message = message_fixture()
      conn = get(conn, ~p"/api/messages/#{message.id}/export")
      assert response_content_type(conn, :xml)
      body = response(conn, 200)
      assert body =~ "urn:oasis:names:tc:emergency:cap:1.2"
      assert body =~ message.identifier
    end

    test "import round-trips an exported document", %{conn: conn} do
      message = message_fixture(%{identifier: "CN-IMPORT-SRC"})
      version = Alerts.latest_version(message)
      xml = CapWorkbench.Cap.Xml.encode(message, version)

      # Change the identifier so the import doesn't collide.
      xml = String.replace(xml, "CN-IMPORT-SRC", "CN-IMPORT-DST")

      conn = post(conn, ~p"/api/messages/import", %{"xml" => xml})
      assert %{"data" => imported} = json_response(conn, 201)
      assert imported["identifier"] == "CN-IMPORT-DST"
    end

    test "import rejects XXE payloads with 422", %{conn: conn} do
      xxe =
        ~s(<?xml version="1.0"?><!DOCTYPE a [<!ENTITY x SYSTEM "file:///etc/passwd">]><alert xmlns="urn:oasis:names:tc:emergency:cap:1.2"><identifier>&x;</identifier></alert>)

      conn = post(conn, ~p"/api/messages/import", %{"xml" => xxe})
      assert %{"error" => %{"code" => "doctype_forbidden"}} = json_response(conn, 422)
    end
  end
end
