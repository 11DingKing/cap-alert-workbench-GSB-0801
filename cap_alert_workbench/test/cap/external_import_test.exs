defmodule CapAlertWorkbench.Cap.ExternalImportTest do
  use CapAlertWorkbench.DataCase, async: false

  alias CapAlertWorkbench.Cap
  alias CapAlertWorkbench.Cap.{Message, OutboxMessage, Version}
  alias CapAlertWorkbench.Repo

  import Ecto.Query

  # External message CN-20260729-GD-RAIN-EXT-02: two info segments, both
  # containing &, <, Chinese quotes (“”) and unknown extension nodes.
  @external_xml ~s{<?xml version="1.0" encoding="UTF-8"?>
<alert xmlns="urn:oasis:names:tc:emergency:cap:1.2" xmlns:gd="urn:gd:cma:cap:ext:1.0">
  <identifier>CN-20260729-GD-RAIN-EXT-02</identifier>
  <sender>external@gd.cma.gov.cn</sender>
  <sent>2026-07-29T09:30:00+00:00</sent>
  <status>Actual</status>
  <msgType>Update</msgType>
  <scope>Public</scope>
  <code>ChangeMe</code>
  <gd:extended source="external">
    <gd:channel>APP &amp; WEB</gd:channel>
    <gd:priority level="1"/>
  </gd:extended>
  <customMeta key="rain &amp; wind">value &lt; 100 “注意”</customMeta>
  <info>
    <language>zh-CN</language>
    <category>Met</category>
    <event>暴雨</event>
    <urgency>Immediate</urgency>
    <severity>Severe</severity>
    <certainty>Likely</certainty>
    <headline>湛江：暴雨与强对流 “红色” 预警 A &amp; B</headline>
    <description>湛江地区降雨 &amp; 雷暴 &lt; 持续 3 小时，请注意“安全”。</description>
    <instruction>停止户外 &amp; 高空作业；若积水 &lt; 30cm 方可通行。</instruction>
    <gd:infoExt tag="zj">本地扩展 &amp; 保留</gd:infoExt>
    <area>
      <areaDesc>湛江市</areaDesc>
      <polygon></polygon>
      <circle></circle>
      <geocode><valueName>AREA_CODE</valueName><value>440800</value></geocode>
      <altitude></altitude>
      <ceiling></ceiling>
    </area>
  </info>
  <info>
    <language>zh-CN</language>
    <category>Met</category>
    <event>暴雨</event>
    <urgency>Immediate</urgency>
    <severity>Extreme</severity>
    <certainty>Observed</certainty>
    <headline>茂名：极端暴雨 “最高级” 预警 X &lt; Y</headline>
    <description>茂名地区已出现特大暴雨 &amp; 洪水风险 &lt;极高&gt;，“立即转移”。</description>
    <instruction>茂名按 Extreme 响应；险情 &amp; 隐患点“必须撤离”。</instruction>
    <gd:infoExt tag="mm">扩展二 &amp; 留存</gd:infoExt>
    <area>
      <areaDesc>茂名市</areaDesc>
      <polygon></polygon>
      <circle></circle>
      <geocode><valueName>AREA_CODE</valueName><value>440900</value></geocode>
      <altitude></altitude>
      <ceiling></ceiling>
    </area>
  </info>
</alert>
}

  defp publish_initial(overrides \\ []) do
    message = Cap.Xml.Codec.seed_message(overrides)

    attrs =
      message
      |> Map.from_struct()
      |> Map.put(:actor, "officer")
      |> Map.to_list()

    {:ok, %{alert: alert}} = Cap.create_alert(attrs)
    {:ok, _} = Cap.submit_for_review(alert.id, "officer")
    {:ok, _} = Cap.decide_review(alert.id, %{"decision" => "approved"}, "reviewer")
    {:ok, %{alert: published}} = Cap.publish(alert.id, "publisher")
    published
  end

  describe "import_xml_for_review/2" do
    test "creates a new alert thread with a single pending-review version, never published" do
      assert {:ok, result} = Cap.import_xml_for_review(@external_xml, "importer")

      alert = result.alert
      assert alert.identifier == "CN-20260729-GD-RAIN-EXT-02"
      assert alert.status == :in_review

      versions = Cap.list_versions(alert.id)
      assert length(versions) == 1
      [version] = versions
      assert version.status == :in_review
      assert version.version_number == 1
      assert version.xml_snapshot =~ "CN-20260729-GD-RAIN-EXT-02"

      # No published version exists.
      assert alert.latest_published_version == nil
      refute Enum.any?(versions, &(&1.status == :published))

      audits = Cap.list_audit_events(alert.id)
      assert Enum.any?(audits, &(&1.action == "external_import"))
    end

    test "round-trips special characters &, <, and Chinese quotes through decode/encode" do
      assert {:ok, result} = Cap.import_xml_for_review(@external_xml, "importer")
      message = result.message

      assert length(message.infos) == 2

      [zj, mm] = message.infos
      assert zj.headline == ~s(湛江：暴雨与强对流 “红色” 预警 A & B)
      assert zj.description == ~s(湛江地区降雨 & 雷暴 < 持续 3 小时，请注意“安全”。)
      assert zj.instruction == ~s(停止户外 & 高空作业；若积水 < 30cm 方可通行。)

      assert mm.headline == ~s(茂名：极端暴雨 “最高级” 预警 X < Y)
      assert mm.description == ~s(茂名地区已出现特大暴雨 & 洪水风险 <极高>，“立即转移”。)

      # Re-encoding escapes the special characters exactly like the source.
      re_encoded = Cap.Xml.Codec.encode!(message)
      assert re_encoded =~ "&amp;"
      assert re_encoded =~ "&lt;"
      refute re_encoded =~ ~s(<script>)

      # Chinese quotes are preserved verbatim (they are not XML metacharacters).
      assert re_encoded =~ "“红色”"
      assert re_encoded =~ "“立即转移”"
    end

    test "preserves area-to-severity correspondence across the two info segments" do
      assert {:ok, result} = Cap.import_xml_for_review(@external_xml, "importer")
      message = result.message

      assert Message.info_for_area(message, "440800").severity == :severe
      assert Message.info_for_area(message, "440900").severity == :extreme
    end

    test "round-trips unknown extension nodes, including nested children and namespaces" do
      assert {:ok, result} = Cap.import_xml_for_review(@external_xml, "importer")
      message = result.message

      # Alert-level extensions.
      extended = Enum.find(message.extensions, &(&1.name == "gd:extended"))
      assert extended != nil
      assert extended.attrs["source"] == "external"

      channel =
        Enum.find(extended.children, fn child ->
          is_map(child) and child.name == "gd:channel"
        end)

      assert channel != nil
      assert channel.children |> Enum.join("") |> String.trim() == "APP & WEB"

      priority =
        Enum.find(extended.children, fn child ->
          is_map(child) and child.name == "gd:priority"
        end)

      assert priority.attrs["level"] == "1"

      custom = Enum.find(message.extensions, &(&1.name == "customMeta"))
      assert custom.attrs["key"] == "rain & wind"
      assert custom.children |> Enum.join("") |> String.trim() == ~s(value < 100 “注意”)

      # Info-level extensions survive on each info segment.
      [zj, mm] = message.infos
      zj_ext = Enum.find(zj.extensions, &(&1.name == "gd:infoExt"))
      assert zj_ext.attrs["tag"] == "zj"
      assert zj_ext.children |> Enum.join("") |> String.trim() == "本地扩展 & 保留"

      mm_ext = Enum.find(mm.extensions, &(&1.name == "gd:infoExt"))
      assert mm_ext.attrs["tag"] == "mm"
      assert mm_ext.children |> Enum.join("") |> String.trim() == "扩展二 & 留存"

      # Extensions survive a full map -> message -> XML round-trip.
      re_encoded = Cap.Xml.Codec.encode!(message)
      assert re_encoded =~ ~s(gd:extended source="external")
      assert re_encoded =~ "APP &amp; WEB"
      assert re_encoded =~ ~s(<gd:priority level="1")
      assert re_encoded =~ ~s(customMeta key="rain &amp; wind")
      assert re_encoded =~ ~s(gd:infoExt tag="zj")
      assert re_encoded =~ "本地扩展 &amp; 保留"
    end

    test "persisted payload and xml_snapshot survive reloading" do
      assert {:ok, result} = Cap.import_xml_for_review(@external_xml, "importer")
      alert_id = result.alert.id

      version =
        Version
        |> where([v], v.alert_id == ^alert_id)
        |> Repo.one!()

      assert {:ok, decoded} = Cap.Xml.Codec.decode(version.xml_snapshot)
      re_encoded = Cap.Xml.Codec.encode!(decoded)
      assert re_encoded == version.xml_snapshot

      [zj, mm] = decoded.infos
      assert zj.headline =~ "“红色”"
      assert mm.description =~ "“立即转移”"
    end

    test "rejects DTD/entity content (XXE defense) even for external messages" do
      xxe =
        ~s{<?xml version="1.0"?><!DOCTYPE alert [<!ENTITY xxe SYSTEM "file:///etc/passwd">]>} <>
          ~s{<alert xmlns="urn:oasis:names:tc:emergency:cap:1.2"><identifier>&xxe;</identifier>} <>
          ~s{<sender>x</sender><sent>2026-07-29T09:30:00+00:00</sent><status>Actual</status>} <>
          ~s{<msgType>Alert</msgType><scope>Public</scope><info><language>zh-CN</language>} <>
          ~s{<category>Met</category><event>暴雨</event><urgency>Immediate</urgency>} <>
          ~s{<severity>Severe</severity><certainty>Likely</certainty></info></alert>}

      assert {:error, {:xml_sax_error, reason}} = Cap.import_xml_for_review(xxe, "importer")

      assert reason in [
               :doctype_not_permitted,
               :entity_not_permitted,
               :external_entity_not_permitted
             ]
    end
  end

  describe "submit_draft_based_on_version/5 stale draft rejection" do
    test "old draft based on pre-C1 (version 1) is rejected with not_latest_version after C1" do
      alert = publish_initial()
      assert {:ok, _} = Cap.create_correction_c1(alert.id, "publisher")

      reloaded = Cap.get_alert!(alert.id)
      assert reloaded.latest_published_version == 2

      # An officer submits a draft that was authored against version 1 (the
      # pre-C1 round). It must be rejected and must not touch the C1 severities.
      assert {:error, {:not_latest_version, 1, 2}} =
               Cap.submit_draft_based_on_version(
                 alert.id,
                 1,
                 reloaded.draft_lock_version,
                 %{"headline" => "旧草稿，会覆盖 C1", "severity" => "severe"},
                 "officer-old"
               )

      # The C1 version's area-level severities are untouched.
      c1 = Repo.one!(from v in Version, where: v.alert_id == ^alert.id and v.version_number == 2)
      c1_message = Cap.Xml.Codec.decode!(c1.xml_snapshot)
      assert Message.info_for_area(c1_message, "440800").severity == :severe
      assert Message.info_for_area(c1_message, "440900").severity == :extreme

      # The working draft was not mutated by the rejected submission.
      unchanged = Cap.get_alert!(alert.id)
      assert unchanged.draft_lock_version == reloaded.draft_lock_version

      # A stale-draft audit event was recorded.
      audits = Cap.list_audit_events(alert.id)
      assert Enum.any?(audits, &(&1.action == "stale_draft_rejected"))

      # No correction/outbox was generated for the rejected draft.
      outbox =
        Repo.all(
          from o in OutboxMessage,
            where: o.alert_id == ^alert.id and o.topic == "alert.corrected"
        )

      assert length(outbox) == 1
    end

    test "draft based on the current latest version is accepted while in draft" do
      # Initial alert is in :draft state with no published version yet.
      message = Cap.Xml.Codec.seed_message([])

      attrs =
        message
        |> Map.from_struct()
        |> Map.put(:actor, "officer")
        |> Map.to_list()

      {:ok, %{alert: alert}} = Cap.create_alert(attrs)

      assert {:ok, result} =
               Cap.submit_draft_based_on_version(
                 alert.id,
                 1,
                 alert.draft_lock_version,
                 %{"headline" => "基于首轮的合法更新"},
                 "officer-new"
               )

      assert result.alert.draft_payload["headline"] == "基于首轮的合法更新"
      assert result.alert.draft_lock_version == alert.draft_lock_version + 1
    end
  end
end
