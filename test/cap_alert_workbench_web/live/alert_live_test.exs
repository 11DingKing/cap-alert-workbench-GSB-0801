defmodule CapAlertWorkbenchWeb.AlertLiveTest do
  use CapAlertWorkbenchWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias CapAlertWorkbench.CapAlert

  @identifier "CN-20260729-GD-RAIN-001"

  @attrs %{
    "identifier" => @identifier,
    "sender" => "duty-officer@gd.example",
    "sent" => ~U[2026-07-29 08:00:00Z],
    "status" => "actual",
    "msg_type" => "alert",
    "scope" => "public",
    "language" => "zh-CN",
    "event" => "暴雨",
    "headline" => "暴雨红色预警",
    "instruction" => "停止集会",
    "urgency" => "immediate",
    "severity" => "severe",
    "certainty" => "likely",
    "geocodes" => %{
      "0" => %{"value_name" => "Same", "value" => "440800"},
      "1" => %{"value_name" => "Same", "value" => "440900"}
    }
  }

  setup do
    {:ok, %{alert: alert, version: version}} = CapAlert.create_alert(@attrs, "test")
    %{alert: alert, version: version}
  end

  test "index lists alerts and links to the workbench", %{conn: conn} do
    {:ok, _index_live, html} = live(conn, ~p"/")
    assert html =~ @identifier
    assert html =~ "duty-officer"
  end

  test "workbench shows editable draft and saves edits", %{conn: conn, version: version} do
    {:ok, view, html} = live(conn, ~p"/alerts/#{@identifier}")

    assert html =~ "草稿"
    assert html =~ "暴雨红色预警"
    assert has_element?(view, "#draft-form")

    # Edit and save the draft
    view
    |> element("#draft-form")
    |> render_submit(%{
      "alert_version" => %{
        "headline" => "更新后的标题",
        "lock_version" => to_string(version.lock_version)
      }
    })

    assert render(view) =~ "更新后的标题"

    reloaded = CapAlert.get_version!(version.id)
    assert reloaded.headline == "更新后的标题"
    assert reloaded.lock_version > version.lock_version
  end

  test "optimistic lock conflict is reported when saving stale data", %{
    conn: conn,
    version: version
  } do
    # Another browser saves first, bumping lock_version
    {:ok, _} =
      CapAlert.edit_draft(
        version,
        %{"headline" => "外部修改", "lock_version" => version.lock_version},
        "other"
      )

    {:ok, view, _html} = live(conn, ~p"/alerts/#{@identifier}")

    render_submit(element(view, "#draft-form"), %{
      "alert_version" => %{
        "headline" => "我的修改",
        "lock_version" => to_string(version.lock_version)
      }
    })

    assert render(view) =~ "乐观锁冲突"
  end

  test "full workflow: submit -> review -> publish -> correction", %{conn: conn, version: version} do
    # Submit for review
    {:ok, view, _} = live(conn, ~p"/alerts/#{@identifier}")
    render_click(view, "submit", %{})
    assert render(view) =~ "待复核"

    # Go to review page and approve
    {:ok, review_view, _} = live(conn, ~p"/alerts/#{@identifier}/review/#{version.id}")
    assert render(review_view) =~ "复核 v1"

    review_view
    |> element("form[phx-submit=approve]")
    |> render_submit(%{"comment" => "同意"})

    # Back to workbench, should be approved, then publish
    {:ok, view, _} = live(conn, ~p"/alerts/#{@identifier}")
    assert render(view) =~ "已通过复核"
    render_click(view, "publish", %{})
    html = render(view)
    assert html =~ "已发布"
    assert html =~ "创建更正"

    # Create a correction
    render_click(view, "create_correction", %{})
    html = render(view)
    assert html =~ "Update"
  end

  test "stale review is rejected when a newer draft exists", %{conn: conn} do
    {:ok, _view, _} = live(conn, ~p"/alerts/#{@identifier}")

    # Get the version into review
    version = CapAlert.list_versions(@identifier) |> hd()
    {:ok, _} = CapAlert.submit_for_review(version, "editor")

    # Author revises (creates v2) while review is pending
    {:ok, _new_draft} = CapAlert.revise(CapAlert.get_version!(version.id), "author")

    # The review LiveView should reject the stale approval and show an error
    {:ok, review_view, _} = live(conn, ~p"/alerts/#{@identifier}/review/#{version.id}")

    html =
      review_view
      |> element("form[phx-submit=approve]")
      |> render_submit(%{"comment" => "stale"})

    assert html =~ "已不是最新"
    refute CapAlert.get_version!(version.id).workflow_state == :approved
  end

  test "version diff page renders changed fields", %{conn: conn, version: v1} do
    {:ok, _} =
      CapAlert.edit_draft(
        v1,
        %{"headline" => "标题已变", "lock_version" => v1.lock_version},
        "editor"
      )

    {:ok, view, html} = live(conn, ~p"/alerts/#{@identifier}/diff/1/1")
    assert html =~ "版本差异对比"
    # The diff table is present
    assert has_element?(view, "table")
  end
end
