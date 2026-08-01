defmodule CapAlertWorkbench.AlertsTest do
  use CapAlertWorkbench.DataCase, async: false

  alias CapAlertWorkbench.Alerts
  alias CapAlertWorkbench.Alerts.{AuditEvent, OutboxEvent, PublishedDocument, Version}
  alias CapAlertWorkbench.Cap.Document

  import Ecto.Query

  # -------------------------------------------------------------------
  # fixtures
  # -------------------------------------------------------------------

  defp payload_fixture(overrides \\ %{}) do
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
      description: "大暴雨到特大暴雨",
      instruction: "立即转移低洼人员",
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

    doc
    |> Document.to_map()
    |> Map.merge(overrides)
  end

  defp stream_fixture(identifier \\ "CN-20260729-GD-RAIN-001") do
    {:ok, %{stream: stream, version: version}} =
      Alerts.create_stream(
        %{
          identifier: identifier,
          sender: "gd-moji@weather.gd.gov.cn",
          payload: payload_fixture()
        },
        "test"
      )

    %{stream: stream, version: version}
  end

  defp approved_version_fixture do
    %{version: version} = stream_fixture()
    {:ok, v} = Alerts.submit_for_review(version.id, version.lock_version, "editor")
    {:ok, v} = Alerts.decide_review(v.id, :approved, "同意", "reviewer", v.lock_version)
    v
  end

  # -------------------------------------------------------------------
  # 创建与标识稳定性
  # -------------------------------------------------------------------

  test "创建消息流：identifier 稳定唯一，首版本为编辑中" do
    %{stream: stream, version: version} = stream_fixture()

    assert stream.identifier == "CN-20260729-GD-RAIN-001"
    assert stream.state == :drafting
    assert version.workflow == :editing
    assert version.version_number == 1
    assert version.lock_version == 1

    assert {:error, :identifier_taken} =
             Alerts.create_stream(
               %{
                 identifier: "CN-20260729-GD-RAIN-001",
                 sender: "gd-moji@weather.gd.gov.cn",
                 payload: payload_fixture()
               },
               "test"
             )
  end

  test "初始 payload 的地区编码保持 440800/440900" do
    %{version: version} = stream_fixture()
    [area] = version.payload["areas"]
    assert Enum.map(area["geocodes"], & &1["value"]) == ["440800", "440900"]
  end

  # -------------------------------------------------------------------
  # 乐观锁：两个浏览器同时编辑同一草稿
  # -------------------------------------------------------------------

  test "乐观锁冲突：旧锁号保存返回 stale_lock，数据以先提交者为准" do
    %{version: version} = stream_fixture()
    assert version.lock_version == 1

    payload_a = payload_fixture(%{"headline" => "浏览器 A 的标题"})
    payload_b = payload_fixture(%{"headline" => "浏览器 B 的标题"})

    # 浏览器 A 先保存（锁号 1）
    assert {:ok, updated} = Alerts.update_draft(version.id, %{payload: payload_a}, 1, "browser-a")
    assert updated.lock_version == 2
    assert updated.payload["headline"] == "浏览器 A 的标题"

    # 浏览器 B 拿着旧锁号 1 保存 → 冲突
    assert {:error, :stale_lock} =
             Alerts.update_draft(version.id, %{payload: payload_b}, 1, "browser-b")

    fresh = Repo.get!(Version, version.id)
    assert fresh.payload["headline"] == "浏览器 A 的标题"
    assert fresh.lock_version == 2
  end

  test "内容未变的保存同样触发乐观锁检查" do
    %{version: version} = stream_fixture()

    # 第一次保存（内容变化）
    assert {:ok, _} =
             Alerts.update_draft(
               version.id,
               %{payload: payload_fixture(%{"headline" => "新标题"})},
               1,
               "a"
             )

    # 第二次保存携带旧锁号，即使内容与库中一致也必须判定为 stale
    assert {:error, :stale_lock} =
             Alerts.update_draft(
               version.id,
               %{payload: payload_fixture(%{"headline" => "新标题"})},
               1,
               "b"
             )
  end

  test "已发布版本不可再编辑" do
    version = approved_version_fixture()
    {:ok, _published} = Alerts.publish(version.id, "editor")

    assert {:error, {:invalid_transition, :published, :edit}} =
             Alerts.update_draft(version.id, %{payload: payload_fixture()}, 2, "editor")
  end

  # -------------------------------------------------------------------
  # 复核竞争：旧复核结论 vs 新草稿
  # -------------------------------------------------------------------

  test "复核钉住锁号：复核期间草稿被修改，旧结论失效返回 stale_review" do
    %{version: version} = stream_fixture()
    {:ok, in_review} = Alerts.submit_for_review(version.id, 1, "editor")
    assert in_review.workflow == :in_review
    assert in_review.lock_version == 1

    # 复核人基于锁号 1 打开页面；同时编辑者在复核中继续改稿
    payload = payload_fixture(%{"headline" => "复核期间的新标题"})
    assert {:ok, revised} = Alerts.update_draft(in_review.id, %{payload: payload}, 1, "editor")
    assert revised.workflow == :in_review
    assert revised.lock_version == 2

    # 旧复核结论（钉住锁号 1）失效
    assert {:error, :stale_review} =
             Alerts.decide_review(in_review.id, :approved, "旧结论", "reviewer", 1)

    # 基于新锁号 2 的复核可以生效
    assert {:ok, approved} =
             Alerts.decide_review(in_review.id, :approved, "重新复核", "reviewer", 2)

    assert approved.workflow == :approved
  end

  test "退回修改后回到编辑中" do
    %{version: version} = stream_fixture()
    {:ok, in_review} = Alerts.submit_for_review(version.id, 1, "editor")

    assert {:ok, rejected} =
             Alerts.decide_review(in_review.id, :rejected, "数据有误", "reviewer", 1)

    assert rejected.workflow == :editing
  end

  test "非法提交复核：复核中不能再提交复核" do
    %{version: version} = stream_fixture()
    {:ok, in_review} = Alerts.submit_for_review(version.id, 1, "editor")

    assert {:error, {:invalid_transition, :in_review, :submit_review}} =
             Alerts.submit_for_review(in_review.id, 1, "editor")
  end

  # -------------------------------------------------------------------
  # 发布
  # -------------------------------------------------------------------

  test "完整发布：版本冻结、审计与 outbox 同事务写入" do
    version = approved_version_fixture()

    assert {:ok, published} = Alerts.publish(version.id, "duty-officer")
    assert published.identifier == "CN-20260729-GD-RAIN-001"
    assert published.msg_type == :alert
    assert published.cap_xml =~ "urn:oasis:names:tc:emergency:cap:1.2"
    assert published.cap_xml =~ "440800"

    fresh = Repo.get!(Version, version.id)
    assert fresh.workflow == :published
    # 版本 payload 已冻结为发布时的 sent，与 XML 一致
    assert fresh.payload["sent"] =~ ~r/\+08:00$/

    assert Repo.get_by!(Alerts.Stream, id: version.stream_id).state == :published

    assert Repo.get_by!(AuditEvent, stream_id: version.stream_id, event: :published)

    assert Repo.get_by!(OutboxEvent,
             stream_id: version.stream_id,
             type: :alert_published,
             status: :pending
           )
  end

  test "重复发布被拒绝：already_published" do
    version = approved_version_fixture()
    {:ok, _published} = Alerts.publish(version.id, "editor")

    assert {:error, :already_published} = Alerts.publish(version.id, "editor")
    assert Repo.aggregate(PublishedDocument, :count) == 1
    assert Repo.aggregate(OutboxEvent, :count) == 1
  end

  test "未复核通过的版本不能发布" do
    %{version: version} = stream_fixture()

    assert {:error, {:invalid_transition, :editing, :publish}} =
             Alerts.publish(version.id, "editor")

    assert Repo.aggregate(PublishedDocument, :count) == 0
  end

  test "两个进程并发发布：只有一个成功" do
    version = approved_version_fixture()
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

    try do
      results =
        [1, 2]
        |> Enum.map(fn _ -> Task.async(fn -> Alerts.publish(version.id, "racer") end) end)
        |> Enum.map(&Task.await/1)

      oks = Enum.count(results, &match?({:ok, _}, &1))
      fails = Enum.count(results, &match?({:error, _}, &1))

      assert oks == 1
      assert fails == 1
      assert Repo.aggregate(PublishedDocument, :count) == 1
      assert Repo.aggregate(from(a in AuditEvent, where: a.event == :published), :count) == 1
      assert Repo.aggregate(OutboxEvent, :count) == 1
    after
      Ecto.Adapters.SQL.Sandbox.mode(Repo, :manual)
    end
  end

  test "发布事务中途失败：全部回滚，状态/审计/outbox 保持一致" do
    version = approved_version_fixture()

    multi =
      version
      |> Alerts.publish_multi("editor")
      |> Ecto.Multi.run(:boom, fn _repo, _changes -> {:error, :simulated_downstream_failure} end)

    assert {:error, :boom, :simulated_downstream_failure, _} = Repo.transaction(multi)

    fresh = Repo.get!(Version, version.id)
    assert fresh.workflow == :approved

    assert Repo.get_by!(Alerts.Stream, id: version.stream_id).state == :drafting
    assert Repo.aggregate(PublishedDocument, :count) == 0
    assert Repo.aggregate(from(a in AuditEvent, where: a.event == :published), :count) == 0
    assert Repo.aggregate(OutboxEvent, :count) == 0

    # 回滚后仍可正常发布
    assert {:ok, _published} = Alerts.publish(version.id, "editor")
  end

  test "只能发布最新草稿版本" do
    version = approved_version_fixture()
    {:ok, _published} = Alerts.publish(version.id, "editor")

    # 发起更正后 v1 不再是可发布对象（状态已 published，且不是最新草稿）
    {:ok, correction} = Alerts.start_correction(version.stream_id, "editor")
    assert correction.version_number == 2

    assert {:error, :not_latest_version} = Alerts.publish(version.id, "editor")
  end

  # -------------------------------------------------------------------
  # 更正与解除
  # -------------------------------------------------------------------

  test "更正基于最新发布版本创建，references 指向已发布文档" do
    version = approved_version_fixture()
    {:ok, _published} = Alerts.publish(version.id, "editor")
    {:ok, correction} = Alerts.start_correction(version.stream_id, "editor")

    assert correction.msg_type == :update
    assert correction.workflow == :editing
    assert correction.version_number == 2

    {:ok, doc} = Document.from_map(correction.payload)
    assert doc.identifier == "CN-20260729-GD-RAIN-001"
    assert doc.msg_type == :update

    assert [%{identifier: "CN-20260729-GD-RAIN-001", sent: sent}] = doc.references
    assert sent =~ ~r/\+08:00$/

    # 更正版本走完整编审流程后发布
    {:ok, v} = Alerts.submit_for_review(correction.id, correction.lock_version, "editor")
    {:ok, v} = Alerts.decide_review(v.id, :approved, nil, "reviewer", v.lock_version)
    {:ok, published2} = Alerts.publish(v.id, "editor")
    assert published2.msg_type == :update
    assert published2.cap_xml =~ "<msgType>Update</msgType>"
    assert published2.cap_xml =~ "<references>"

    assert Repo.get_by!(OutboxEvent, version_id: v.id).type == :alert_corrected
  end

  test "解除发布后消息流进入 cancelled，此后不能再更正" do
    version = approved_version_fixture()
    {:ok, _published} = Alerts.publish(version.id, "editor")

    {:ok, cancellation} = Alerts.start_cancellation(version.stream_id, "editor")
    assert cancellation.msg_type == :cancel

    {:ok, v} = Alerts.submit_for_review(cancellation.id, cancellation.lock_version, "editor")
    {:ok, v} = Alerts.decide_review(v.id, :approved, nil, "reviewer", v.lock_version)
    {:ok, cancelled_doc} = Alerts.publish(v.id, "editor")
    assert cancelled_doc.msg_type == :cancel

    stream = Repo.get_by!(Alerts.Stream, id: version.stream_id)
    assert stream.state == :cancelled

    assert Repo.get_by!(OutboxEvent, version_id: v.id).type == :alert_cancelled

    assert {:error, {:invalid_transition, :cancelled, :start_followup}} =
             Alerts.start_correction(version.stream_id, "editor")
  end

  test "存在活动草稿时不能重复发起更正/解除" do
    version = approved_version_fixture()
    {:ok, _published} = Alerts.publish(version.id, "editor")

    {:ok, _correction} = Alerts.start_correction(version.stream_id, "editor")

    assert {:error, :draft_already_exists} =
             Alerts.start_correction(version.stream_id, "editor")

    assert {:error, :draft_already_exists} =
             Alerts.start_cancellation(version.stream_id, "editor")
  end

  test "未发布的消息流不能发起更正/解除" do
    %{stream: stream} = stream_fixture()

    assert {:error, {:invalid_transition, :drafting, :start_followup}} =
             Alerts.start_correction(stream.id, "editor")
  end

  # -------------------------------------------------------------------
  # XML 导入导出与差异
  # -------------------------------------------------------------------

  test "导出的 CAP XML round-trip 与版本 payload 一致" do
    %{version: version} = stream_fixture()
    {:ok, xml} = Alerts.export_cap_xml(version.id)

    assert xml =~ ~s(<?xml version="1.0")
    assert {:ok, doc} = CapAlertWorkbench.Cap.Xml.parse(xml)
    assert doc.identifier == "CN-20260729-GD-RAIN-001"
    assert doc.areas |> hd() |> Map.get(:geocodes) |> Enum.map(& &1.value) == ["440800", "440900"]
  end

  test "导入 CAP XML 创建新消息流并写入导入审计" do
    xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <alert xmlns="urn:oasis:names:tc:emergency:cap:1.2">
      <identifier>CN-20260801-GD-WIND-002</identifier>
      <sender>gd-moji@weather.gd.gov.cn</sender>
      <sent>2026-08-01T10:00:00+08:00</sent>
      <status>Actual</status>
      <msgType>Alert</msgType>
      <scope>Public</scope>
      <info>
        <language>zh-CN</language>
        <category>Met</category>
        <event>雷雨大风</event>
        <urgency>Immediate</urgency>
        <severity>Moderate</severity>
        <certainty>Likely</certainty>
        <area><areaDesc>湛江市</areaDesc>
          <geocode><valueName>region</valueName><value>440800</value></geocode>
        </area>
      </info>
    </alert>
    """

    assert {:ok, %{stream: stream, version: version}} = Alerts.import_cap_xml(xml, "importer")
    assert stream.identifier == "CN-20260801-GD-WIND-002"
    assert version.workflow == :editing
    assert Repo.get_by!(AuditEvent, stream_id: stream.id, event: :imported)

    assert {:error, :identifier_taken} = Alerts.import_cap_xml(xml, "importer")
  end

  test "版本差异按字段返回" do
    %{version: version} = stream_fixture()
    payload = payload_fixture(%{"headline" => "新标题", "severity" => "Extreme"})
    {:ok, updated} = Alerts.update_draft(version.id, %{payload: payload}, 1, "editor")

    diff = Alerts.diff_versions(version, updated)

    assert diff["headline"] == {"暴雨红色预警", "新标题"}
    assert diff["severity"] == {"Severe", "Extreme"}
    refute Map.has_key?(diff, "event")
  end
end
