defmodule CapWorkbench.ExternalImportScenarioTest do
  @moduledoc """
  Scenario: an external CAP message with two info segments (each carrying `&`,
  `<`, Chinese quotation marks, and unknown extension nodes) is imported, and a
  stale draft — based on a correction's pre-publish version — is submitted.

  Requirements exercised here:

    * import produces a NEW message whose sole version is pending review;
    * special characters and unknown extension nodes survive an
      import → export → import round-trip unchanged;
    * submitting an out-of-date draft version returns `:not_latest_version`
      and does not clobber the latest version's per-region severities.
  """
  use CapWorkbench.DataCase, async: true

  import CapWorkbench.AlertsFixtures

  alias CapWorkbench.Alerts
  alias CapWorkbench.Cap.Xml

  # Two info segments. Region 440800 (揭阳) stays Severe; 440900 (茂名) Extreme.
  # Each headline/description mixes raw `&`, `<`, and Chinese quotes “ ” .
  # Each info carries an unknown extension node (<gdext:*>) the workbench does
  # not model natively; the alert level carries one too.
  @external_xml """
  <?xml version="1.0" encoding="utf-8"?>
  <alert xmlns="urn:oasis:names:tc:emergency:cap:1.2" xmlns:gdext="urn:gd:ext:1.0">
    <identifier>CN-20260729-GD-RAIN-EXT-02</identifier>
    <sender>ext@partner.example</sender>
    <sent>2026-07-29T18:00:00+08:00</sent>
    <status>Actual</status>
    <msgType>Alert</msgType>
    <scope>Public</scope>
    <gdext:batch id="B&amp;7">批次&lt;二&gt;“加急”</gdext:batch>
    <info>
      <language>zh-CN</language>
      <category>Met</category>
      <event>暴雨与强对流</event>
      <urgency>Immediate</urgency>
      <severity>Severe</severity>
      <certainty>Likely</certainty>
      <headline>揭阳 A&amp;B &lt;红色&gt; “强降水”</headline>
      <description>范围 a &lt; b &amp; c，含“中文引号”。</description>
      <area>
        <areaDesc>揭阳市</areaDesc>
        <geocode><valueName>SAME</valueName><value>440800</value></geocode>
      </area>
      <gdext:confidence level="high">来源“可靠” &amp; 校验&lt;通过&gt;</gdext:confidence>
    </info>
    <info>
      <language>zh-CN</language>
      <category>Met</category>
      <event>暴雨与强对流</event>
      <urgency>Immediate</urgency>
      <severity>Extreme</severity>
      <certainty>Likely</certainty>
      <headline>茂名 X&amp;Y &lt;特别严重&gt; “极端”</headline>
      <description>雨量 p &gt; q &amp; r，标注“峰值”。</description>
      <area>
        <areaDesc>茂名市</areaDesc>
        <geocode><valueName>SAME</valueName><value>440900</value></geocode>
      </area>
      <gdext:confidence level="max">复核“确认” &amp; 状态&lt;锁定&gt;</gdext:confidence>
    </info>
  </alert>
  """

  describe "importing the external two-info message" do
    test "creates a new drafting message with a single pending version" do
      {:ok, parsed} = Xml.decode(@external_xml)
      {:ok, message} = Alerts.create_message(Map.merge(parsed.message, parsed.version), "导入")

      assert message.identifier == "CN-20260729-GD-RAIN-EXT-02"
      assert message.msg_type == :alert
      assert message.workflow_state == :drafting

      # Import only ever yields ONE version, awaiting review.
      assert [version] = message.versions
      assert version.version_number == 1
      assert version.review_state == :pending
      refute version.published

      # Two info segments preserved with their per-region severities.
      by_geocode =
        version.infos
        |> Enum.flat_map(fn info -> Enum.map(info.geocodes, &{&1, info.severity}) end)
        |> Map.new()

      assert by_geocode["440800"] == :severe
      assert by_geocode["440900"] == :extreme
    end

    test "special characters and unknown extension nodes round-trip unchanged" do
      {:ok, parsed} = Xml.decode(@external_xml)
      {:ok, message} = Alerts.create_message(Map.merge(parsed.message, parsed.version), "导入")

      version = Alerts.latest_version(message)

      # Special characters decoded to their real glyphs on the way in.
      info_800 = Enum.find(version.infos, &("440800" in &1.geocodes))
      info_900 = Enum.find(version.infos, &("440900" in &1.geocodes))

      assert info_800.headline == "揭阳 A&B <红色> “强降水”"
      assert info_800.description == "范围 a < b & c，含“中文引号”。"
      assert info_900.headline == "茂名 X&Y <特别严重> “极端”"
      assert info_900.description == "雨量 p > q & r，标注“峰值”。"

      # Unknown extension nodes captured per info + at the alert level.
      assert Enum.any?(info_800.extensions["info"], &(&1["name"] =~ "confidence"))
      assert Enum.any?(info_900.extensions["info"], &(&1["name"] =~ "confidence"))
      assert Enum.any?(version.extensions["alert"], &(&1["name"] =~ "batch"))

      # Re-export, then re-import: the second parse must equal the first.
      exported = Xml.encode(message, version)

      # Encoder must escape, never emit raw specials inside text.
      assert exported =~ "&amp;"
      assert exported =~ "&lt;"
      assert exported =~ "&gt;"
      # Unknown nodes and their attributes survive.
      assert exported =~ "confidence"
      assert exported =~ "batch"

      {:ok, reparsed} = Xml.decode(exported)

      re_800 = Enum.find(reparsed.version.infos, &("440800" in &1["geocodes"]))
      re_900 = Enum.find(reparsed.version.infos, &("440900" in &1["geocodes"]))

      assert re_800["headline"] == info_800.headline
      assert re_800["description"] == info_800.description
      assert re_900["headline"] == info_900.headline
      assert re_900["description"] == info_900.description

      # Extension nodes (with attributes + special-char content) still present.
      assert Enum.any?(re_800["extensions"]["info"], fn n ->
               n["name"] =~ "confidence" and
                 Enum.any?(n["content"], &(is_binary(&1) and &1 =~ "校验<通过>"))
             end)

      assert Enum.any?(reparsed.version.extensions["alert"], fn n ->
               n["name"] =~ "batch" and Enum.any?(n["attributes"], &(&1 == ["id", "B&7"]))
             end)
    end
  end

  describe "submitting a stale draft based on a correction's pre-publish version" do
    test "returns :not_latest_version and keeps round-2 per-region severities" do
      # Round 1: publish both regions at Severe.
      published = published_message_fixture()

      # Round 2: correction C1 raises 440900 -> Extreme (440800 stays Severe).
      {:ok, c1} =
        Alerts.create_correction(published, %{region_severities: %{"440900" => :extreme}}, "值班员")

      stale_version = Alerts.latest_version(c1)
      stale_lock = c1.lock_version

      # An operator edits C1, producing a newer version (round-2 work continues).
      # A real edit sends the FULL info set; here we only tweak one headline while
      # preserving both regions and their severities.
      edited_infos =
        Enum.map(stale_version.infos, fn info ->
          map = Alerts.info_to_map(info)
          if "440900" in info.geocodes, do: Map.put(map, "headline", "茂名更新标题"), else: map
        end)

      {:ok, c1} =
        Alerts.save_new_version(c1, %{"infos" => edited_infos}, stale_lock, "值班员")

      # A concurrent actor holding the OLD version tries to submit it.
      assert {:error, :not_latest_version} =
               Alerts.submit_for_review(c1, stale_version, c1.lock_version, "值班员")

      # The latest version still carries round-2's per-region severities intact.
      latest = Alerts.latest_version(c1)

      by_geocode =
        latest.infos
        |> Enum.flat_map(fn info -> Enum.map(info.geocodes, &{&1, info.severity}) end)
        |> Map.new()

      assert by_geocode["440800"] == :severe
      assert by_geocode["440900"] == :extreme
    end
  end
end
