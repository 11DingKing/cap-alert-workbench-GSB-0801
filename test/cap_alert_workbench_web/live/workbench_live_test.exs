defmodule CapAlertWorkbenchWeb.WorkbenchLiveTest do
  use CapAlertWorkbenchWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias CapAlertWorkbench.Alerts
  alias CapAlertWorkbench.Cap.{Document, Info}

  defp draft_params(info_overrides \\ %{}, lock_version \\ "1") do
    info =
      %{
        "event" => "暴雨及强对流天气",
        "headline" => "暴雨红色预警",
        "language" => "zh-CN",
        "category" => "Met",
        "urgency" => "Immediate",
        "severity" => "Severe",
        "certainty" => "Likely",
        "geocodes" => "440800, 440900",
        "area_desc" => "湛江市、茂名市",
        "description" => "描述",
        "instruction" => "建议"
      }
      |> Map.merge(info_overrides)

    %{
      "status" => "Actual",
      "lock_version" => lock_version,
      "infos" => %{"0" => info}
    }
  end

  setup do
    doc = %Document{
      identifier: "CN-20260729-GD-RAIN-001",
      sender: "gd-moji@weather.gd.gov.cn",
      sent: "2026-07-29T08:00:00+08:00",
      status: :actual,
      msg_type: :alert,
      scope: :public,
      infos: [
        %Info{
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
    assert has_element?(view, "#draft-geocodes-0")

    # 编辑草稿
    view
    |> form("#draft-form", draft: draft_params(%{"headline" => "暴雨红色预警（修订）"}))
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

    # 第一个浏览器保存成功
    view |> form("#draft-form", draft: draft_params()) |> render_submit()

    # 同一表单（旧锁号 1）再次提交 → 冲突提示（绕过 DOM 值校验模拟陈旧页面）
    html = render_submit(view, "save_draft", %{"draft" => draft_params()})
    assert html =~ "乐观锁冲突"
  end

  test "拆分 info 段并分地区设置严重度", %{conn: conn, stream: stream} do
    {:ok, view, _html} = live(conn, ~p"/streams/#{stream.id}")

    # 拆分为两个 info 段（通过表单提交 form_action=add_info）
    render_submit(view, "save_draft", %{
      "draft" => draft_params(),
      "form_action" => "add_info"
    })

    assert has_element?(view, "#info-fieldset-0")
    assert has_element?(view, "#info-fieldset-1")

    # 第一段 440800 维持 Severe，第二段 440900 升级 Extreme
    two_infos = %{
      "status" => "Actual",
      "lock_version" => "1",
      "infos" => %{
        "0" => %{
          "event" => "暴雨及强对流天气",
          "headline" => "湛江维持暴雨红色预警",
          "language" => "zh-CN",
          "category" => "Met",
          "urgency" => "Immediate",
          "severity" => "Severe",
          "certainty" => "Likely",
          "geocodes" => "440800",
          "area_desc" => "湛江市",
          "description" => "描述",
          "instruction" => "建议"
        },
        "1" => %{
          "event" => "暴雨及强对流天气",
          "headline" => "茂名升级为暴雨红色预警（极端）",
          "language" => "zh-CN",
          "category" => "Met",
          "urgency" => "Immediate",
          "severity" => "Extreme",
          "certainty" => "Likely",
          "geocodes" => "440900",
          "area_desc" => "茂名市",
          "description" => "描述",
          "instruction" => "建议"
        }
      }
    }

    render_submit(view, "save_draft", %{"draft" => two_infos})

    {:ok, detail} = Alerts.get_stream_detail(stream.id)
    [info1, info2] = detail.active_draft.payload["infos"]
    assert info1["severity"] == "Severe"
    assert info2["severity"] == "Extreme"
  end

  test "发布后提供更正入口，更正草稿标识为 -C1 且携带 references", %{
    conn: conn,
    stream: stream,
    version: version
  } do
    {:ok, v} = Alerts.submit_for_review(version.id, 1, "editor")
    {:ok, v} = Alerts.decide_review(v.id, :approved, nil, "reviewer", 1)
    {:ok, _pub} = Alerts.publish(v.id, "editor")

    {:ok, view, _html} = live(conn, ~p"/streams/#{stream.id}")
    view |> element("#btn-start-correction") |> render_click()

    assert has_element?(view, "#draft-form")

    {:ok, detail} = Alerts.get_stream_detail(stream.id)
    assert detail.active_draft.msg_type == :update
    assert detail.active_draft.payload["identifier"] == "CN-20260729-GD-RAIN-001-C1"
    assert detail.active_draft.payload["references"] != []
  end

  test "版本差异页按地区展示 440800 未变化 / 440900 Severe→Extreme", %{
    conn: conn,
    stream: stream,
    version: version
  } do
    {:ok, v} = Alerts.submit_for_review(version.id, 1, "editor")
    {:ok, v} = Alerts.decide_review(v.id, :approved, nil, "reviewer", 1)
    {:ok, _pub} = Alerts.publish(v.id, "editor")
    {:ok, correction} = Alerts.start_correction(stream.id, "editor")

    base_info = %{
      "event" => "暴雨及强对流天气",
      "language" => "zh-CN",
      "category" => "Met",
      "urgency" => "Immediate",
      "certainty" => "Likely",
      "description" => "描述",
      "instruction" => "处置建议"
    }

    payload_params = %{
      "status" => "Actual",
      "infos" => %{
        "0" =>
          Map.merge(base_info, %{
            "headline" => "暴雨红色预警",
            "severity" => "Severe",
            "geocodes" => "440800",
            "area_desc" => "湛江市"
          }),
        "1" =>
          Map.merge(base_info, %{
            "headline" => "茂名升级为暴雨红色预警（极端）",
            "severity" => "Extreme",
            "geocodes" => "440900",
            "area_desc" => "茂名市"
          })
      }
    }

    {:ok, payload} = Alerts.compose_payload(correction, payload_params)

    {:ok, edited} =
      Alerts.update_draft(correction.id, %{payload: payload}, correction.lock_version, "editor")

    {:ok, view, _html} = live(conn, ~p"/streams/#{stream.id}")

    view
    |> form("#diff-form", %{a: version.id, b: edited.id})
    |> render_submit()

    assert has_element?(view, "#area-diff-440800", "未变化")
    assert has_element?(view, "#area-diff-440900", "有变更")
    assert has_element?(view, "#area-diff-440900", "Severe")
    assert has_element?(view, "#area-diff-440900", "Extreme")
  end
end
