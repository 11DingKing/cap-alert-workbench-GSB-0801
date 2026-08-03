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
    "infos" => %{
      "0" => %{
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

  test "workbench shows editable draft with multi-info and saves edits", %{
    conn: conn,
    version: version
  } do
    {:ok, view, html} = live(conn, ~p"/alerts/#{@identifier}")

    assert html =~ "草稿"
    assert html =~ "暴雨红色预警"
    assert has_element?(view, "#draft-form")

    view
    |> element("#draft-form")
    |> render_submit(%{
      "alert_version" => %{
        "infos" => %{
          "0" => %{
            "event" => "暴雨",
            "headline" => "更新后的标题",
            "severity" => "severe",
            "geocodes" => %{
              "0" => %{"value_name" => "Same", "value" => "440800"},
              "1" => %{"value_name" => "Same", "value" => "440900"}
            }
          }
        },
        "lock_version" => to_string(version.lock_version)
      }
    })

    assert render(view) =~ "更新后的标题"

    reloaded = CapAlert.get_version!(version.id)
    assert hd(reloaded.infos).headline == "更新后的标题"
    assert reloaded.lock_version > version.lock_version
  end

  test "optimistic lock conflict is reported when saving stale data", %{
    conn: conn,
    version: version
  } do
    {:ok, _} =
      CapAlert.edit_draft(
        version,
        %{
          "infos" => %{
            "0" => %{
              "event" => "暴雨",
              "headline" => "外部修改",
              "severity" => "severe",
              "geocodes" => %{
                "0" => %{"value_name" => "Same", "value" => "440800"},
                "1" => %{"value_name" => "Same", "value" => "440900"}
              }
            }
          },
          "lock_version" => version.lock_version
        },
        "other"
      )

    {:ok, view, _html} = live(conn, ~p"/alerts/#{@identifier}")

    render_submit(element(view, "#draft-form"), %{
      "alert_version" => %{
        "infos" => %{
          "0" => %{
            "event" => "暴雨",
            "headline" => "我的修改",
            "severity" => "severe",
            "geocodes" => %{
              "0" => %{"value_name" => "Same", "value" => "440800"}
            }
          }
        },
        "lock_version" => to_string(version.lock_version)
      }
    })

    assert render(view) =~ "乐观锁冲突"
  end

  test "full workflow: submit -> review -> publish -> create C1", %{conn: conn, version: version} do
    {:ok, view, _} = live(conn, ~p"/alerts/#{@identifier}")
    render_click(view, "submit", %{})
    assert render(view) =~ "待复核"

    {:ok, review_view, _} = live(conn, ~p"/alerts/#{@identifier}/review/#{version.id}")
    assert render(review_view) =~ "复核 v1"

    review_view
    |> element("form[phx-submit=approve]")
    |> render_submit(%{"comment" => "同意"})

    {:ok, view, _} = live(conn, ~p"/alerts/#{@identifier}")
    assert render(view) =~ "已通过复核"
    render_click(view, "publish", %{})
    html = render(view)
    assert html =~ "已发布"
    assert html =~ "创建更正 C1"

    render_click(view, "create_c1", %{})

    c1_id = "#{@identifier}-C1"
    c1 = CapAlert.get_alert!(c1_id)
    assert c1 != nil
    c1_version = CapAlert.get_version!(c1.latest_version_id)
    assert c1_version.msg_type == :update
    assert length(c1_version.infos) == 2

    assert {:ok, c1_view, _} = live(conn, ~p"/alerts/#{c1_id}")
    assert render(c1_view) =~ "C1"
    assert render(c1_view) =~ "Extreme"
  end

  test "stale review is rejected when a newer draft exists", %{conn: conn} do
    {:ok, _view, _} = live(conn, ~p"/alerts/#{@identifier}")

    version = CapAlert.list_versions(@identifier) |> hd()
    {:ok, _} = CapAlert.submit_for_review(version, "editor")

    {:ok, _new_draft} = CapAlert.revise(CapAlert.get_version!(version.id), "author")

    {:ok, review_view, _} = live(conn, ~p"/alerts/#{@identifier}/review/#{version.id}")

    html =
      review_view
      |> element("form[phx-submit=approve]")
      |> render_submit(%{"comment" => "stale"})

    assert html =~ "已不是最新"
    refute CapAlert.get_version!(version.id).workflow_state == :approved
  end

  test "per-region diff page renders changed fields", %{conn: conn, version: v1} do
    {:ok, _} =
      CapAlert.edit_draft(
        v1,
        %{
          "infos" => %{
            "0" => %{
              "event" => "暴雨",
              "headline" => "标题已变",
              "severity" => "severe",
              "geocodes" => %{
                "0" => %{"value_name" => "Same", "value" => "440800"},
                "1" => %{"value_name" => "Same", "value" => "440900"}
              }
            }
          },
          "lock_version" => v1.lock_version
        },
        "editor"
      )

    {:ok, view, html} = live(conn, ~p"/alerts/#{@identifier}/diff/1/1")
    assert html =~ "版本差异对比"
    assert has_element?(view, "table")
  end
end
