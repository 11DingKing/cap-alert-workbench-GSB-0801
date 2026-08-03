defmodule CapWorkbenchWeb.MessageLiveTest do
  use CapWorkbenchWeb.ConnCase

  import Phoenix.LiveViewTest
  import CapWorkbench.AlertsFixtures

  alias CapWorkbench.Alerts

  describe "Index" do
    test "lists messages", %{conn: conn} do
      message = message_fixture()
      {:ok, _view, html} = live(conn, ~p"/messages")
      assert html =~ message.identifier
      assert html =~ "预警编审工作台"
    end

    test "creates a new draft through the form", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/messages/new")

      attrs = %{
        "identifier" => "CN-LIVE-0001",
        "sender" => "cap@gd.gov.cn",
        "sent_at" => "2026-07-29T08:00",
        "status" => "actual",
        "msg_type" => "alert",
        "scope" => "public",
        "language" => "zh-CN",
        "category" => "met",
        "event" => "暴雨",
        "urgency" => "immediate",
        "severity" => "severe",
        "certainty" => "likely",
        "headline" => "标题",
        "description" => "描述",
        "instruction" => "建议",
        "area_description" => "揭阳",
        "geocodes" => "440800, 440900"
      }

      view
      |> form("#new-message-form", draft: attrs)
      |> render_submit()

      assert_redirect(view)
      assert [msg] = Enum.filter(Alerts.list_messages(), &(&1.identifier == "CN-LIVE-0001"))
      assert msg.workflow_state == :drafting
    end
  end

  describe "Show workflow" do
    test "submit -> approve -> publish drives the message to published", %{conn: conn} do
      message = message_fixture()
      {:ok, view, _html} = live(conn, ~p"/messages/#{message.id}")

      assert has_element?(view, "#submit-review-btn")
      view |> element("#submit-review-btn") |> render_click()

      # Move to review tab and approve.
      view |> element("#tab-review") |> render_click()
      assert has_element?(view, "#approve-btn")
      view |> element("#approve-btn") |> render_click()

      # Publish becomes available.
      assert has_element?(view, "#publish-btn")
      view |> element("#publish-btn") |> render_click()

      reloaded = Alerts.get_message!(message.id)
      assert reloaded.workflow_state == :published
    end

    test "published message exposes per-region correction on the publish tab and hides editor form",
         %{
           conn: conn
         } do
      message = published_message_fixture()
      {:ok, view, _html} = live(conn, ~p"/messages/#{message.id}")

      # Editor form is gone once frozen.
      refute has_element?(view, "#edit-form")
      # Cancellation is a top-level action.
      assert has_element?(view, "#cancellation-btn")

      # The per-region correction UI lives on the publish/output tab.
      view |> element("#tab-publish") |> render_click()
      assert has_element?(view, "#correction-panel")
      assert has_element?(view, "#correction-btn")
      assert has_element?(view, "#region-sev-440800")
      assert has_element?(view, "#region-sev-440900")
    end

    test "per-region correction from the UI splits 440900 to Extreme", %{conn: conn} do
      message = published_message_fixture()
      {:ok, view, _html} = live(conn, ~p"/messages/#{message.id}")

      view |> element("#tab-publish") |> render_click()

      # Raise only 440900 to Extreme.
      view
      |> element("#region-form-440900")
      |> render_change(%{"geocode" => "440900", "severity" => "extreme"})

      view |> element("#correction-btn") |> render_click()

      correction =
        Alerts.list_messages()
        |> Enum.find(&(&1.references_message_id == message.id))

      assert correction.identifier == message.identifier <> "-C1"

      severities =
        Alerts.latest_version(correction).infos
        |> Enum.flat_map(fn info -> Enum.map(info.geocodes, &{&1, info.severity}) end)
        |> Map.new()

      assert severities["440800"] == :severe
      assert severities["440900"] == :extreme
    end

    test "a change from another session live-syncs into an open workbench", %{conn: conn} do
      message = message_fixture()
      {:ok, view, _html} = live(conn, ~p"/messages/#{message.id}")

      # Another browser/session saves a new version, bumping lock + adding v2.
      info_map = Alerts.info_to_map(hd(Alerts.latest_version(message).infos))
      {:ok, _} = Alerts.save_new_version(message, %{"infos" => [info_map]}, message.lock_version)

      # The open LiveView is notified via PubSub and reloads, so it now reflects
      # the latest lock version and keeps page/version state consistent — the
      # operator cannot act on stale data.
      html = render(view)
      assert html =~ "该消息在另一处发生变更"
      assert html =~ "锁版本 v2"
    end
  end
end
