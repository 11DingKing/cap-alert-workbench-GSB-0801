defmodule CapAlertWorkbench.AlertsTest do
  use CapAlertWorkbench.DataCase, async: false

  alias CapAlertWorkbench.Alerts
  alias CapAlertWorkbench.Alerts.{AuditEvent, OutboxEvent, PublishedDocument, Version}
  alias CapAlertWorkbench.Cap.{Document, Info}

  import Ecto.Query

  # -------------------------------------------------------------------
  # fixtures
  # -------------------------------------------------------------------

  defp info_fixture(overrides \\ %{}) do
    info = %Info{
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

    Map.merge(info, overrides)
  end

  defp payload_fixture(infos \\ nil) do
    doc = %Document{
      identifier: "CN-20260729-GD-RAIN-001",
      sender: "gd-moji@weather.gd.gov.cn",
      sent: "2026-07-29T08:00:00+08:00",
      status: :actual,
      msg_type: :alert,
      scope: :public,
      infos: infos || [info_fixture()]
    }

    Document.to_map(doc)
  end

  # 多 info 段：440800 维持 Severe（其余字段与基线一致），440900 升级 Extreme。
  # 基于既有版本 payload 合并，保留 identifier/references。
  defp split_infos_payload(base_payload) do
    info_440800 =
      info_fixture(%{
        areas: [
          %{area_desc: "湛江市", geocodes: [%{value_name: "region", value: "440800"}]}
        ]
      })

    info_440900 =
      info_fixture(%{
        severity: :extreme,
        headline: "茂名升级为暴雨红色预警（极端）",
        description: "茂名市雨势进一步增强",
        areas: [
          %{area_desc: "茂名市", geocodes: [%{value_name: "region", value: "440900"}]}
        ]
      })

    Map.put(base_payload, "infos", [Info.to_map(info_440800), Info.to_map(info_440900)])
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

  # 发布首轮，并发起更正草稿
  defp correction_fixture do
    version = approved_version_fixture()
    {:ok, published} = Alerts.publish(version.id, "editor")
    {:ok, correction} = Alerts.start_correction(version.stream_id, "editor")
    %{version: version, published: published, correction: correction}
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
    [info] = version.payload["infos"]
    [area] = info["areas"]
    assert Enum.map(area["geocodes"], & &1["value"]) == ["440800", "440900"]
  end

  # -------------------------------------------------------------------
  # 乐观锁：两个浏览器同时编辑同一草稿
  # -------------------------------------------------------------------

  test "乐观锁冲突：旧锁号保存返回 stale_lock，数据以先提交者为准" do
    %{version: version} = stream_fixture()
    assert version.lock_version == 1

    info_a = info_fixture(%{headline: "浏览器 A 的标题"})
    info_b = info_fixture(%{headline: "浏览器 B 的标题"})

    # 浏览器 A 先保存（锁号 1）
    assert {:ok, updated} =
             Alerts.update_draft(
               version.id,
               %{payload: payload_fixture([info_a])},
               1,
               "browser-a"
             )

    assert updated.lock_version == 2
    assert hd(updated.payload["infos"])["headline"] == "浏览器 A 的标题"

    # 浏览器 B 拿着旧锁号 1 保存 → 冲突
    assert {:error, :stale_lock} =
             Alerts.update_draft(
               version.id,
               %{payload: payload_fixture([info_b])},
               1,
               "browser-b"
             )

    fresh = Repo.get!(Version, version.id)
    assert hd(fresh.payload["infos"])["headline"] == "浏览器 A 的标题"
    assert fresh.lock_version == 2
  end

  test "内容未变的保存同样触发乐观锁检查" do
    %{version: version} = stream_fixture()

    assert {:ok, _} =
             Alerts.update_draft(
               version.id,
               %{payload: payload_fixture([info_fixture(%{headline: "新标题"})])},
               1,
               "a"
             )

    assert {:error, :stale_lock} =
             Alerts.update_draft(
               version.id,
               %{payload: payload_fixture([info_fixture(%{headline: "新标题"})])},
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
    payload = payload_fixture([info_fixture(%{headline: "复核期间的新标题"})])

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
    %{version: version, correction: correction} = correction_fixture()
    assert correction.version_number == 2

    assert {:error, :not_latest_version} = Alerts.publish(version.id, "editor")
  end

  # -------------------------------------------------------------------
  # 更正：C1 派生、references、多 info 并发编审发布
  # -------------------------------------------------------------------

  test "更正标识派生为 -C1，references 精确指向首轮发布文档" do
    %{published: published, correction: correction} = correction_fixture()

    assert correction.msg_type == :update
    assert correction.workflow == :editing

    {:ok, doc} = Document.from_map(correction.payload)
    assert doc.identifier == "CN-20260729-GD-RAIN-001-C1"
    assert doc.msg_type == :update

    assert [%{identifier: "CN-20260729-GD-RAIN-001", sent: ref_sent}] = doc.references
    {:ok, published_doc} = CapAlertWorkbench.Cap.Xml.parse(published.cap_xml)
    assert ref_sent == published_doc.sent
  end

  test "更正草稿可编辑为多 info 段（440800 Severe / 440900 Extreme）后发布" do
    %{correction: correction} = correction_fixture()

    payload = split_infos_payload(correction.payload)

    {:ok, updated} =
      Alerts.update_draft(correction.id, %{payload: payload}, correction.lock_version, "editor")

    assert length(updated.payload["infos"]) == 2

    {:ok, v} = Alerts.submit_for_review(updated.id, updated.lock_version, "editor")
    {:ok, v} = Alerts.decide_review(v.id, :approved, nil, "reviewer", v.lock_version)
    {:ok, published_c1} = Alerts.publish(v.id, "editor")

    assert published_c1.identifier == "CN-20260729-GD-RAIN-001-C1"
    assert published_c1.msg_type == :update
    assert published_c1.cap_xml =~ "<msgType>Update</msgType>"

    assert published_c1.cap_xml =~
             "<references>gd-moji@weather.gd.gov.cn,CN-20260729-GD-RAIN-001,"

    assert length(Regex.scan(~r/<info>/, published_c1.cap_xml)) == 2
    assert published_c1.cap_xml =~ "Extreme"

    assert Repo.get_by!(OutboxEvent, version_id: v.id).type == :alert_corrected
  end

  test "并发复核与发布：旧结论失效、不会产生第二份 C1 文档或 outbox" do
    %{correction: correction} = correction_fixture()

    payload = split_infos_payload(correction.payload)

    # 两个浏览器同时编辑：第一个成功，第二个（旧锁号）失败
    {:ok, edited} =
      Alerts.update_draft(correction.id, %{payload: payload}, correction.lock_version, "editor-a")

    assert {:error, :stale_lock} =
             Alerts.update_draft(
               correction.id,
               %{payload: payload},
               correction.lock_version,
               "editor-b"
             )

    {:ok, in_review} = Alerts.submit_for_review(edited.id, edited.lock_version, "editor-a")

    # 复核期间编辑者再改稿 → 复核结论（旧锁号）失效
    revised_payload = split_infos_payload(edited.payload)

    {:ok, revised} =
      Alerts.update_draft(
        in_review.id,
        %{payload: revised_payload},
        in_review.lock_version,
        "editor-a"
      )

    assert {:error, :stale_review} =
             Alerts.decide_review(
               in_review.id,
               :approved,
               "旧结论",
               "reviewer-1",
               in_review.lock_version
             )

    {:ok, approved} =
      Alerts.decide_review(in_review.id, :approved, "重新复核", "reviewer-1", revised.lock_version)

    # 并发发布：只有一个成功
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

    try do
      results =
        [1, 2]
        |> Enum.map(fn _ -> Task.async(fn -> Alerts.publish(approved.id, "racer") end) end)
        |> Enum.map(&Task.await/1)

      assert Enum.count(results, &match?({:ok, _}, &1)) == 1
      assert Enum.count(results, &match?({:error, _}, &1)) == 1

      # C1 文档与 outbox 全局唯一（在共享事务内断言，避免模式切换后失联）
      assert Repo.aggregate(
               from(p in PublishedDocument,
                 where: p.identifier == "CN-20260729-GD-RAIN-001-C1"
               ),
               :count
             ) == 1

      assert Repo.aggregate(
               from(o in OutboxEvent, where: o.type == :alert_corrected),
               :count
             ) == 1
    after
      Ecto.Adapters.SQL.Sandbox.mode(Repo, :manual)
    end
  end

  test "解除消息 C2：引用已发布 C1，保留多 info，版本链完整，重复发布幂等" do
    # 第 1 轮：首发；第 2 轮：C1 更正（440800 Severe / 440900 Extreme）发布
    %{version: v1, correction: correction} = correction_fixture()

    {:ok, edited} =
      Alerts.update_draft(
        correction.id,
        %{payload: split_infos_payload(correction.payload)},
        correction.lock_version,
        "editor"
      )

    {:ok, v} = Alerts.submit_for_review(edited.id, edited.lock_version, "editor")
    {:ok, v} = Alerts.decide_review(v.id, :approved, nil, "reviewer", v.lock_version)
    {:ok, published_c1} = Alerts.publish(v.id, "editor")
    assert published_c1.identifier == "CN-20260729-GD-RAIN-001-C1"

    # 第 3 轮：解除消息 C2，引用第 2 轮已发布 C1
    {:ok, cancellation} = Alerts.start_cancellation(v1.stream_id, "editor")
    {:ok, cancel_doc} = Document.from_map(cancellation.payload)

    assert cancel_doc.identifier == "CN-20260729-GD-RAIN-001-C2"
    assert cancel_doc.msg_type == :cancel

    # references 精确指向已发布 C1（标识 + sent 与冻结 XML 一致）
    {:ok, c1_doc} = CapAlertWorkbench.Cap.Xml.parse(published_c1.cap_xml)

    assert [%{identifier: "CN-20260729-GD-RAIN-001-C1", sent: ref_sent}] = cancel_doc.references
    assert ref_sent == c1_doc.sent

    # 保留多 info 解析结果：地区-严重度对应关系不变
    [ci1, ci2] = cancel_doc.infos
    assert Info.geocodes(ci1) == ["440800"]
    assert ci1.severity == :severe
    assert Info.geocodes(ci2) == ["440900"]
    assert ci2.severity == :extreme

    # C2 走完整编审流程后发布
    {:ok, cv} = Alerts.submit_for_review(cancellation.id, cancellation.lock_version, "editor")
    {:ok, cv} = Alerts.decide_review(cv.id, :approved, nil, "reviewer", cv.lock_version)
    {:ok, published_c2} = Alerts.publish(cv.id, "editor")
    assert published_c2.identifier == "CN-20260729-GD-RAIN-001-C2"
    assert published_c2.msg_type == :cancel
    assert published_c2.cap_xml =~ "<msgType>Cancel</msgType>"

    assert published_c2.cap_xml =~
             "<references>gd-moji@weather.gd.gov.cn,CN-20260729-GD-RAIN-001-C1,"

    stream = Repo.get_by!(Alerts.Stream, id: v1.stream_id)
    assert stream.state == :cancelled

    # 重复发布请求幂等：不产生第二份文档 / outbox / 审计
    assert {:error, :already_published} = Alerts.publish(cv.id, "editor")
    assert Repo.aggregate(PublishedDocument, :count) == 3
    assert Repo.aggregate(from(a in AuditEvent, where: a.event == :published), :count) == 3
    assert Repo.aggregate(OutboxEvent, :count) == 3
    assert Repo.get_by!(OutboxEvent, version_id: cv.id).type == :alert_cancelled

    # 解除后仍可查看完整版本链
    {:ok, detail} = Alerts.get_stream_detail(v1.stream_id)

    assert Enum.map(detail.versions, &{&1.version_number, &1.workflow, &1.msg_type}) == [
             {1, :published, :alert},
             {2, :published, :update},
             {3, :published, :cancel}
           ]

    assert Enum.map(detail.published_documents, & &1.identifier) |> Enum.sort() == [
             "CN-20260729-GD-RAIN-001",
             "CN-20260729-GD-RAIN-001-C1",
             "CN-20260729-GD-RAIN-001-C2"
           ]

    # 每次状态转换均有审计记录
    events = Enum.map(detail.audit_events, & &1.event)

    for expected <- [
          :stream_created,
          :submitted_for_review,
          :review_approved,
          :published,
          :correction_started,
          :cancellation_started
        ] do
      assert expected in events, "缺少审计事件 #{expected}"
    end
  end

  test "解除后不能再发起更正/解除" do
    %{version: v1, correction: correction} = correction_fixture()

    {:ok, v} = Alerts.submit_for_review(correction.id, correction.lock_version, "editor")
    {:ok, v} = Alerts.decide_review(v.id, :approved, nil, "reviewer", v.lock_version)
    {:ok, _c1} = Alerts.publish(v.id, "editor")

    {:ok, cancellation} = Alerts.start_cancellation(v1.stream_id, "editor")
    {:ok, cv} = Alerts.submit_for_review(cancellation.id, cancellation.lock_version, "editor")
    {:ok, cv} = Alerts.decide_review(cv.id, :approved, nil, "reviewer", cv.lock_version)
    {:ok, _c2} = Alerts.publish(cv.id, "editor")

    assert {:error, {:invalid_transition, :cancelled, :start_followup}} =
             Alerts.start_correction(v1.stream_id, "editor")

    assert {:error, {:invalid_transition, :cancelled, :start_followup}} =
             Alerts.start_cancellation(v1.stream_id, "editor")
  end

  test "存在活动草稿时不能重复发起更正/解除" do
    %{version: version} = correction_fixture()

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
  # 多 info 编辑合成
  # -------------------------------------------------------------------

  test "compose_payload 多 info 形态：按段独立设置严重度" do
    %{correction: correction} = correction_fixture()

    params = %{
      "status" => "Actual",
      "infos" => %{
        "0" => %{
          "event" => "暴雨及强对流天气",
          "headline" => "湛江维持",
          "language" => "zh-CN",
          "category" => "Met",
          "urgency" => "Immediate",
          "severity" => "Severe",
          "certainty" => "Likely",
          "geocodes" => "440800",
          "area_desc" => "湛江市",
          "description" => "描述1",
          "instruction" => "建议1"
        },
        "1" => %{
          "event" => "暴雨及强对流天气",
          "headline" => "茂名升级",
          "language" => "zh-CN",
          "category" => "Met",
          "urgency" => "Immediate",
          "severity" => "Extreme",
          "certainty" => "Likely",
          "geocodes" => "440900",
          "area_desc" => "茂名市",
          "description" => "描述2",
          "instruction" => "建议2"
        }
      }
    }

    assert {:ok, payload} = Alerts.compose_payload(correction, params)
    [info1, info2] = payload["infos"]
    assert info1["severity"] == "Severe"
    assert info2["severity"] == "Extreme"
    # identifier / references 保持稳定
    assert payload["identifier"] == "CN-20260729-GD-RAIN-001-C1"
    assert payload["references"] != []
  end

  test "compose_payload 扁平形态：仅作用于首个 info 段" do
    %{correction: correction} = correction_fixture()

    assert {:ok, payload} =
             Alerts.compose_payload(correction, %{"headline" => "扁平标题", "severity" => "Extreme"})

    [info1] = payload["infos"]
    assert info1["headline"] == "扁平标题"
    assert info1["severity"] == "Extreme"
  end

  # -------------------------------------------------------------------
  # XML 导入导出与差异
  # -------------------------------------------------------------------

  test "导出的多 info CAP XML 导入后地区-严重度对应关系完整 round-trip" do
    %{correction: correction} = correction_fixture()

    {:ok, updated} =
      Alerts.update_draft(
        correction.id,
        %{payload: split_infos_payload(correction.payload)},
        correction.lock_version,
        "editor"
      )

    {:ok, xml} = Alerts.export_cap_xml(updated.id)
    assert {:ok, doc} = CapAlertWorkbench.Cap.Xml.parse(xml)
    assert doc.identifier == "CN-20260729-GD-RAIN-001-C1"

    [i1, i2] = doc.infos
    assert Info.geocodes(i1) == ["440800"]
    assert i1.severity == :severe
    assert Info.geocodes(i2) == ["440900"]
    assert i2.severity == :extreme

    # 再序列化再解析，结构不变
    assert {:ok, doc2} = CapAlertWorkbench.Cap.Xml.parse(CapAlertWorkbench.Cap.Xml.serialize(doc))
    assert doc2 == doc
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

  @ext02_xml """
  <?xml version="1.0" encoding="UTF-8"?>
  <alert xmlns="urn:oasis:names:tc:emergency:cap:1.2">
    <identifier>CN-20260729-GD-RAIN-EXT-02</identifier>
    <sender>ext-feed@partner.example.cn</sender>
    <sent>2026-07-29T09:30:00+08:00</sent>
    <status>Actual</status>
    <msgType>Alert</msgType>
    <scope>Public</scope>
    <info>
      <language>zh-CN</language>
      <category>Met</category>
      <event>暴雨 &amp; 强对流</event>
      <urgency>Immediate</urgency>
      <severity>Severe</severity>
      <certainty>Likely</certainty>
      <headline>“湛江”暴雨红色预警 &lt;外部转发&gt;</headline>
      <description>湛江市有大暴雨 &amp; 雷暴大风，注意“城乡积涝”风险</description>
      <area>
        <areaDesc>湛江市</areaDesc>
        <geocode><valueName>region</valueName><value>440800</value></geocode>
      </area>
      <x:evac xmlns:x="http://ext.example/evac" x:level="2">转移 &amp; 安置“低洼区”</x:evac>
    </info>
    <info>
      <language>zh-CN</language>
      <category>Met</category>
      <event>暴雨 &amp; 强对流</event>
      <urgency>Immediate</urgency>
      <severity>Extreme</severity>
      <certainty>Likely</certainty>
      <headline>“茂名”升级为极端暴雨 &lt;特急&gt;</headline>
      <description>茂名市雨势“极端”增强 &amp; 伴有龙卷风险</description>
      <area>
        <areaDesc>茂名市</areaDesc>
        <geocode><valueName>region</valueName><value>440900</value></geocode>
      </area>
      <x:shelter xmlns:x="http://ext.example/evac" x:capacity="5000">避难场所 &lt;名单&gt; &amp; 容量</x:shelter>
    </info>
  </alert>
  """

  test "导入外部多 info 消息：特殊字符与扩展节点完整 round-trip，仅生成待复核版本" do
    assert {:ok, %{stream: stream, version: version}} =
             Alerts.import_cap_xml(@ext02_xml, "importer")

    assert stream.identifier == "CN-20260729-GD-RAIN-EXT-02"
    # 导入只生成待复核草稿，不绕过编审流程
    assert version.workflow == :editing

    assert {:error, {:invalid_transition, :editing, :publish}} =
             Alerts.publish(version.id, "importer")

    # 导出再解析：与原始文档逐字段相等（特殊字符、扩展节点、地区-严重度对应）
    {:ok, exported} = Alerts.export_cap_xml(version.id)
    assert {:ok, original} = CapAlertWorkbench.Cap.Xml.parse(@ext02_xml)
    assert {:ok, round_tripped} = CapAlertWorkbench.Cap.Xml.parse(exported)
    assert round_tripped == original

    [i1, i2] = round_tripped.infos
    assert i1.headline == "“湛江”暴雨红色预警 <外部转发>"
    assert i1.description =~ "“城乡积涝”"
    assert i1.severity == :severe
    assert Info.geocodes(i1) == ["440800"]
    assert length(i1.extensions) == 1

    assert i2.headline == "“茂名”升级为极端暴雨 <特急>"
    assert i2.severity == :extreme
    assert Info.geocodes(i2) == ["440900"]
    assert length(i2.extensions) == 1

    # 扩展节点内容未被吞掉
    assert exported =~ "转移 &amp; 安置“低洼区”"
    assert exported =~ "避难场所 &lt;名单&gt; &amp; 容量"
    assert exported =~ ~s(x:capacity="5000")
  end

  test "基于 C1 发布前版本的旧草稿：发布返回 not_latest_version，不覆盖更正稿" do
    %{version: v1, correction: correction} = correction_fixture()

    # 更正稿设定地区级严重度（440800 Severe / 440900 Extreme）
    {:ok, edited} =
      Alerts.update_draft(
        correction.id,
        %{payload: split_infos_payload(correction.payload)},
        correction.lock_version,
        "editor"
      )

    # 旧草稿（v1）发起发布 → not_latest_version
    assert {:error, :not_latest_version} = Alerts.publish(v1.id, "stale-editor")

    # 旧草稿（v1，已发布冻结）尝试编辑 → 拒绝
    assert {:error, {:invalid_transition, :published, :edit}} =
             Alerts.update_draft(v1.id, %{payload: payload_fixture()}, 2, "stale-editor")

    # 第 2 轮（更正稿）的地区级严重度未被覆盖
    fresh = Repo.get!(Version, edited.id)
    [i1, i2] = fresh.payload["infos"]
    assert i1["severity"] == "Severe"
    assert i2["severity"] == "Extreme"
    assert Repo.get_by!(Alerts.Stream, id: v1.stream_id).state == :published
  end

  test "版本差异按字段返回（多 info 路径）" do
    %{version: version} = stream_fixture()

    {:ok, updated} =
      Alerts.update_draft(
        version.id,
        %{payload: payload_fixture([info_fixture(%{headline: "新标题", severity: :extreme})])},
        1,
        "editor"
      )

    diff = Alerts.diff_versions(version, updated)

    assert diff["info1.headline"] == {"暴雨红色预警", "新标题"}
    assert diff["info1.severity"] == {"Severe", "Extreme"}
    refute Map.has_key?(diff, "info1.event")
  end

  test "按地区差异：440800 未变化，440900 Severe→Extreme" do
    %{version: version, correction: correction} = correction_fixture()

    {:ok, edited} =
      Alerts.update_draft(
        correction.id,
        %{payload: split_infos_payload(correction.payload)},
        correction.lock_version,
        "editor"
      )

    areas = Alerts.diff_areas(version, edited)

    by_geocode = Map.new(areas, &{&1.geocode, &1})

    assert by_geocode["440800"].status == :unchanged
    assert by_geocode["440900"].status == :changed

    assert {"severity", "Severe", "Extreme"} in by_geocode["440900"].changes
    assert {"headline", "暴雨红色预警", "茂名升级为暴雨红色预警（极端）"} in by_geocode["440900"].changes
  end
end
