defmodule CapAlertWorkbenchWeb.Api.MessageControllerTest do
  use CapAlertWorkbenchWeb.ConnCase, async: false

  alias CapAlertWorkbench.Alerts
  alias CapAlertWorkbench.Cap.Document

  defp create_stream(_ctx) do
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

  setup :create_stream

  test "GET /api/streams 列表", %{conn: conn, stream: stream} do
    conn = get(conn, ~p"/api/streams")

    assert %{"data" => [%{"identifier" => "CN-20260729-GD-RAIN-001", "state" => "drafting"}]} =
             json_response(conn, 200)

    conn = get(build_conn(), ~p"/api/streams/#{stream.id}")
    assert %{"data" => %{"identifier" => _, "versions" => [_]}} = json_response(conn, 200)
  end

  test "POST draft 乐观锁冲突返回 409", %{conn: conn, version: version} do
    params = %{
      "lock_version" => 1,
      "actor" => "a",
      "draft" => %{"headline" => "A 的标题"}
    }

    conn = post(conn, ~p"/api/versions/#{version.id}/draft", params)
    assert %{"data" => %{"lock_version" => 2}} = json_response(conn, 200)

    stale = %{"lock_version" => 1, "actor" => "b", "draft" => %{"headline" => "B 的标题"}}
    conn = post(build_conn(), ~p"/api/versions/#{version.id}/draft", stale)
    assert %{"error" => %{"code" => "stale_lock"}} = json_response(conn, 409)
  end

  test "完整流程：提交复核 → 复核 → 发布 → 重复发布 409", %{conn: conn, version: version} do
    conn =
      post(conn, ~p"/api/versions/#{version.id}/submit-review", %{
        "lock_version" => 1,
        "actor" => "editor"
      })

    assert %{"data" => %{"workflow" => "in_review"}} = json_response(conn, 200)

    conn =
      post(build_conn(), ~p"/api/versions/#{version.id}/review", %{
        "decision" => "approved",
        "pinned_lock_version" => 1,
        "reviewer" => "r1"
      })

    assert %{"data" => %{"workflow" => "approved"}} = json_response(conn, 200)

    conn = post(build_conn(), ~p"/api/versions/#{version.id}/publish", %{"actor" => "editor"})
    assert %{"data" => %{"identifier" => "CN-20260729-GD-RAIN-001"}} = json_response(conn, 200)

    conn = post(build_conn(), ~p"/api/versions/#{version.id}/publish", %{"actor" => "editor"})
    assert %{"error" => %{"code" => "already_published"}} = json_response(conn, 409)
  end

  test "复核期间草稿变更使旧复核结论失效", %{conn: conn, version: version} do
    post(conn, ~p"/api/versions/#{version.id}/submit-review", %{
      "lock_version" => 1,
      "actor" => "editor"
    })

    post(build_conn(), ~p"/api/versions/#{version.id}/draft", %{
      "lock_version" => 1,
      "actor" => "editor",
      "draft" => %{"headline" => "复核期间改稿"}
    })

    conn =
      post(build_conn(), ~p"/api/versions/#{version.id}/review", %{
        "decision" => "approved",
        "pinned_lock_version" => 1,
        "reviewer" => "r1"
      })

    assert %{"error" => %{"code" => "stale_review"}} = json_response(conn, 409)
  end

  test "CAP XML 导出与导入 round-trip", %{conn: conn, version: version} do
    conn = get(conn, ~p"/api/versions/#{version.id}/cap.xml")
    assert response_content_type(conn, :xml)
    xml = response(conn, 200)
    assert xml =~ "CN-20260729-GD-RAIN-001"
    assert xml =~ "440800"

    imported = String.replace(xml, "CN-20260729-GD-RAIN-001", "CN-20260801-GD-RAIN-009")

    conn =
      build_conn()
      |> put_req_header("content-type", "application/xml")
      |> put_req_header("accept", "application/xml")
      |> post(~p"/api/streams/import", imported)

    assert %{"data" => %{"stream_id" => _}} = json_response(conn, 201)
  end

  test "导入含 DOCTYPE 的 XML 被拒绝", %{conn: conn} do
    xxe = """
    <?xml version="1.0"?>
    <!DOCTYPE alert [<!ENTITY xxe SYSTEM "file:///etc/passwd">]>
    <alert xmlns="urn:oasis:names:tc:emergency:cap:1.2">
      <identifier>&xxe;</identifier>
    </alert>
    """

    conn =
      conn
      |> put_req_header("content-type", "application/xml")
      |> put_req_header("accept", "application/xml")
      |> post(~p"/api/streams/import", xxe)

    assert %{"error" => %{"code" => "doctype_forbidden"}} = json_response(conn, 422)
  end

  test "更正与解除 API", %{conn: conn, stream: stream, version: version} do
    post(conn, ~p"/api/versions/#{version.id}/submit-review", %{
      "lock_version" => 1,
      "actor" => "editor"
    })

    post(build_conn(), ~p"/api/versions/#{version.id}/review", %{
      "decision" => "approved",
      "pinned_lock_version" => 1,
      "reviewer" => "r1"
    })

    post(build_conn(), ~p"/api/versions/#{version.id}/publish", %{"actor" => "editor"})

    conn = post(build_conn(), ~p"/api/streams/#{stream.id}/corrections", %{"actor" => "editor"})

    assert %{"data" => %{"msg_type" => "update", "version_number" => 2}} =
             json_response(conn, 201)

    conn = post(build_conn(), ~p"/api/streams/#{stream.id}/corrections", %{"actor" => "editor"})
    assert %{"error" => %{"code" => "draft_already_exists"}} = json_response(conn, 409)
  end
end
