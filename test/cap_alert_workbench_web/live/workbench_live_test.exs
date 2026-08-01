defmodule CapAlertWorkbenchWeb.WorkbenchLiveTest do
  use CapAlertWorkbenchWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias CapAlertWorkbench.Alerts
  alias CapAlertWorkbench.Cap.Document

  setup do
    doc = %Document{
      identifier: "CN-20260729-GD-RAIN-001",
      sender: "gd-moji@weather.gd.gov.cn",
      sent: "2026-07-29T08:00:00+08:00",
      status: :actual,
      msg_type: :alert,
      scope: :public,
      language: "zh-CN",
      category: :met,
      event: "暴雨及强对流天气",
      urgency: :immediate,
      severity: :severe,
      certainty: :likely,
      headline: "暴雨红色预警",
      description: "描述",
      instruction: "处置建议",
      areas: [
        %{
          area_desc: "湛江市、茂名市",
          geocodes: [
            %{value_name: "region", value: "440800"},
            %{value_name: "region", value: "440900"}
          ]
        }
      ]
    }

    {:ok, %{stream: stream, version: version}} =
      Alerts.create_stream(
        %{identifier: doc.identifier, sender: doc.sender, payload: Document.to_map(doc)},
        "test"
      )

    %{stream: stream, version: version}
  end

  test "首页列出消息流", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/")
    assert html =~ "CN-20260729-GD-RAIN-001"
    assert html =~ "公共预警编审工作台"
  end

  test "完整编审发布流程", %{conn: conn, stream: stream, version: version} do
    {:ok, view, _html} = live(conn, ~p"/streams/#{stream.id}")

    assert has_element?(view, "#draft-form")
    assert has_element?(view, "#draft-geocodes")

    # 编辑草稿
    view
    |> form("#draft-form",
      draft: %{
        "headline" => "暴雨红色预警（修订）",
        "event" => "暴雨及强对流天气",
        "language" => "zh-CN",
        "status" => "Actual",
        "category" => "Met",
        "urgency" => "Immediate",
        "severity" => "Severe",
        "certainty" => "Likely",
        "geocodes" => "440800, 440900",
        "area_desc" => "湛江市、茂名市",
        "description" => "描述",
        "instruction" => "处置建议",
        "lock_version" => "1"
      }
    )
    |> render_submit()

    assert Alerts.get_version(version.id) |> elem(1) |> Map.get(:lock_version) == 2

    # 提交复核
    view |> element("#btn-submit-review") |> render_click()
    assert has_element?(view, "#review-panel")

    # 复核通过
    view
    |> form("#review-form", %{note: "同意发布"})
    |> render_submit(%{"decision" => "approved"})

    assert has_element?(view, "#publish-panel")

    # 发布
    view |> element("#btn-publish") |> render_click()
    assert has_element?(view, "#btn-start-correction")

    {:ok, detail} = Alerts.get_stream_detail(stream.id)
    assert length(detail.published_documents) == 1
    assert Enum.any?(detail.outbox_events, &(&1.type == :alert_published))
  end

  test "乐观锁冲突在页面上提示", %{conn: conn, stream: stream, version: _version} do
    {:ok, view, _html} = live(conn, ~p"/streams/#{stream.id}")

    base_draft = %{
      "headline" => "标题",
      "event" => "暴雨及强对流天气",
      "language" => "zh-CN",
      "status" => "Actual",
      "category" => "Met",
      "urgency" => "Immediate",
      "severity" => "Severe",
      "certainty" => "Likely",
      "geocodes" => "440800, 440900",
      "area_desc" => "湛江市、茂名市",
      "description" => "描述",
      "instruction" => "建议",
      "lock_version" => "1"
    }

    # 第一个浏览器保存成功
    view |> form("#draft-form", draft: base_draft) |> render_submit()

    # 同一表单（旧锁号 1）再次提交 → 冲突提示（绕过 DOM 值校验模拟陈旧页面）
    html = render_submit(view, "save_draft", %{"draft" => base_draft})
    assert html =~ "乐观锁冲突"
  end

  test "发布后提供更正入口，更正草稿携带 references", %{conn: conn, stream: stream, version: version} do
    {:ok, v} = Alerts.submit_for_review(version.id, 1, "editor")
    {:ok, v} = Alerts.decide_review(v.id, :approved, nil, "reviewer", 1)
    {:ok, _pub} = Alerts.publish(v.id, "editor")

    {:ok, view, _html} = live(conn, ~p"/streams/#{stream.id}")
    view |> element("#btn-start-correction") |> render_click()

    assert has_element?(view, "#draft-form")

    {:ok, detail} = Alerts.get_stream_detail(stream.id)
    assert detail.active_draft.msg_type == :update
    assert detail.active_draft.payload["references"] != []
  end
end
