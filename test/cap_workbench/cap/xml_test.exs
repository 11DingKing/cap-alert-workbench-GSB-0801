defmodule CapWorkbench.Cap.XmlTest do
  use CapWorkbench.DataCase, async: true

  alias CapWorkbench.Alerts
  alias CapWorkbench.Cap.Xml

  import CapWorkbench.AlertsFixtures

  describe "encode/2" do
    test "renders CAP 1.2 namespace and TitleCase tokens" do
      message = message_fixture()
      version = Alerts.latest_version(message)
      xml = Xml.encode(message, version)

      assert xml =~ ~s(xmlns="urn:oasis:names:tc:emergency:cap:1.2")
      assert xml =~ "<status>Actual</status>"
      assert xml =~ "<msgType>Alert</msgType>"
      assert xml =~ "<scope>Public</scope>"
      assert xml =~ "<urgency>Immediate</urgency>"
      assert xml =~ "<severity>Severe</severity>"
      assert xml =~ "<certainty>Likely</certainty>"
      assert xml =~ "<value>440800</value>"
      assert xml =~ "<value>440900</value>"
    end

    test "escapes special characters instead of concatenating raw" do
      message =
        message_fixture(%{
          infos: [
            valid_info(%{"headline" => "暴雨 & 大风 <紧急> \"红色\"", "description" => "a < b & c > d"})
          ]
        })

      version = Alerts.latest_version(message)
      xml = Xml.encode(message, version)

      # Raw special chars must be escaped by the encoder.
      assert xml =~ "&amp;"
      assert xml =~ "&lt;"
      assert xml =~ "&gt;"
      refute xml =~ "<紧急>"
      # And it must round-trip back to the exact original text.
      assert {:ok, parsed} = Xml.decode(xml)
      [info] = parsed.version.infos
      assert info["headline"] == "暴雨 & 大风 <紧急> \"红色\""
      assert info["description"] == "a < b & c > d"
    end
  end

  describe "decode/1 round-trip" do
    test "encode |> decode preserves core fields incl. Chinese text" do
      message = message_fixture()
      version = Alerts.latest_version(message)
      xml = Xml.encode(message, version)

      assert {:ok, parsed} = Xml.decode(xml)
      assert parsed.message.identifier == message.identifier
      assert parsed.message.status == :actual
      assert parsed.message.msg_type == :alert
      assert parsed.message.scope == :public

      [info] = parsed.version.infos
      assert info["category"] == :met
      assert info["urgency"] == :immediate
      assert info["severity"] == :severe
      assert info["certainty"] == :likely
      assert info["geocodes"] == ["440800", "440900"]
      assert info["headline"] == hd(version.infos).headline
      assert info["description"] == hd(version.infos).description
    end

    test "multiple info blocks preserve per-region severity correspondence" do
      # 440800 stays Severe; 440900 raised to Extreme — two distinct info blocks.
      message =
        message_fixture(%{
          infos: [
            valid_info(%{
              "severity" => :severe,
              "geocodes" => ["440800"],
              "area_description" => "揭阳市"
            }),
            valid_info(%{
              "severity" => :extreme,
              "geocodes" => ["440900"],
              "area_description" => "茂名市",
              "headline" => "茂名暴雨特别严重"
            })
          ]
        })

      version = Alerts.latest_version(message)
      xml = Xml.encode(message, version)

      # Two <info> and two <area> segments must be emitted.
      assert length(Regex.scan(~r/<info>/, xml)) == 2

      assert {:ok, parsed} = Xml.decode(xml)
      assert length(parsed.version.infos) == 2

      by_geocode =
        Map.new(parsed.version.infos, fn info -> {hd(info["geocodes"]), info["severity"]} end)

      assert by_geocode["440800"] == :severe
      assert by_geocode["440900"] == :extreme
    end

    test "handles namespace prefixes on elements" do
      xml = """
      <?xml version="1.0" encoding="utf-8"?>
      <cap:alert xmlns:cap="urn:oasis:names:tc:emergency:cap:1.2">
        <cap:identifier>CN-NS-001</cap:identifier>
        <cap:sender>cap@gd.gov.cn</cap:sender>
        <cap:sent>2026-07-29T16:00:00+08:00</cap:sent>
        <cap:status>Actual</cap:status>
        <cap:msgType>Alert</cap:msgType>
        <cap:scope>Public</cap:scope>
        <cap:info>
          <cap:language>zh-CN</cap:language>
          <cap:category>Met</cap:category>
          <cap:event>暴雨</cap:event>
          <cap:urgency>Immediate</cap:urgency>
          <cap:severity>Severe</cap:severity>
          <cap:certainty>Likely</cap:certainty>
          <cap:headline>标题</cap:headline>
          <cap:description>描述</cap:description>
          <cap:area>
            <cap:areaDesc>茂名</cap:areaDesc>
            <cap:geocode><cap:valueName>SAME</cap:valueName><cap:value>440900</cap:value></cap:geocode>
          </cap:area>
        </cap:info>
      </cap:alert>
      """

      assert {:ok, parsed} = Xml.decode(xml)
      assert parsed.message.identifier == "CN-NS-001"
      assert parsed.message.status == :actual
      [info] = parsed.version.infos
      assert info["certainty"] == :likely
      assert info["geocodes"] == ["440900"]
    end

    test "preserves unknown extension fields for round-trip export" do
      xml = """
      <?xml version="1.0" encoding="utf-8"?>
      <alert xmlns="urn:oasis:names:tc:emergency:cap:1.2">
        <identifier>CN-EXT-001</identifier>
        <sender>cap@gd.gov.cn</sender>
        <sent>2026-07-29T16:00:00+08:00</sent>
        <status>Actual</status>
        <msgType>Alert</msgType>
        <scope>Public</scope>
        <customTopLevel>alert-ext-value</customTopLevel>
        <info>
          <language>zh-CN</language>
          <category>Met</category>
          <event>暴雨</event>
          <urgency>Immediate</urgency>
          <severity>Severe</severity>
          <certainty>Likely</certainty>
          <headline>标题</headline>
          <description>描述</description>
          <parameter><valueName>customKey</valueName><value>customVal &amp; more</value></parameter>
          <area>
            <areaDesc>茂名</areaDesc>
            <geocode><valueName>SAME</valueName><value>440900</value></geocode>
          </area>
        </info>
      </alert>
      """

      assert {:ok, parsed} = Xml.decode(xml)
      assert [%{"name" => alert_ext}] = parsed.version.extensions["alert"]
      assert alert_ext =~ "customTopLevel"

      [info] = parsed.version.infos
      info_ext = info["extensions"]["info"]
      assert Enum.any?(info_ext, &(&1["name"] =~ "parameter"))

      # Now persist + re-encode and confirm the extension survives export.
      {:ok, message} = Alerts.create_message(Map.merge(parsed.message, parsed.version), "tester")
      version = Alerts.latest_version(message)
      exported = Xml.encode(message, version)

      assert exported =~ "customTopLevel"
      assert exported =~ "customKey"
      # The escaped ampersand inside the unknown value must survive.
      assert exported =~ "customVal &amp; more"
    end
  end

  describe "security: no external entities" do
    test "rejects documents with a DOCTYPE (XXE vector)" do
      xxe =
        ~s(<?xml version="1.0"?><!DOCTYPE a [<!ENTITY x SYSTEM "file:///etc/passwd">]><alert xmlns="urn:oasis:names:tc:emergency:cap:1.2"><identifier>&x;</identifier></alert>)

      assert {:error, :doctype_forbidden} = Xml.decode(xxe)
    end

    test "does not expand a general entity reference into file contents" do
      # Even without DOCTYPE, an entity ref must not be expanded/resolved.
      xml =
        ~s(<alert xmlns="urn:oasis:names:tc:emergency:cap:1.2"><identifier>&xxe;</identifier><info></info></alert>)

      # Parser keeps entity verbatim (expand_entity: :never); decode fails on
      # missing required fields, but never touches the filesystem.
      assert {:error, _} = Xml.decode(xml)
    end

    test "malformed xml returns a descriptive error, not a crash" do
      assert {:error, {:malformed_xml, _}} = Xml.decode("<alert><oops>")
    end

    test "unknown status token is rejected rather than coerced" do
      xml = """
      <alert xmlns="urn:oasis:names:tc:emergency:cap:1.2">
        <identifier>X</identifier><sender>s</sender>
        <sent>2026-07-29T16:00:00+08:00</sent>
        <status>Bogus</status><msgType>Alert</msgType><scope>Public</scope>
        <info><category>Met</category><urgency>Immediate</urgency>
        <severity>Severe</severity><certainty>Likely</certainty></info>
      </alert>
      """

      assert {:error, {:invalid_token, "status", "Bogus"}} = Xml.decode(xml)
    end
  end
end
