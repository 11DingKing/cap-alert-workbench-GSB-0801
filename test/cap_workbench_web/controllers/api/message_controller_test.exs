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
      attrs = valid_attrs() |> Map.new(fn {k, v} -> {Atom.to_string(k), stringify(v)} end)

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
      {:ok, _} = Alerts.save_new_version(message, %{"headline" => "先手"}, stale)

      conn =
        post(conn, ~p"/api/messages/#{message.id}/versions", %{
          "version" => %{"headline" => "后手"},
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

  defp stringify(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp stringify(atom) when is_atom(atom) and not is_nil(atom), do: Atom.to_string(atom)
  defp stringify(other), do: other
end
