defmodule CapAlertWorkbench.CapAlert.CapXmlTest do
  use ExUnit.Case, async: true

  alias CapAlertWorkbench.CapAlert.CapXml

  @sample_xml ~s"""
  <?xml version="1.0" encoding="UTF-8"?>
  <alert xmlns="urn:oasis:names:tc:emergency:cap:1.2">
    <identifier>CN-20260729-GD-RAIN-001</identifier>
    <sender>duty-officer@gd.example</sender>
    <sent>2026-07-29T08:00:00+00:00</sent>
    <status>Actual</status>
    <msgType>Alert</msgType>
    <scope>Public</scope>
    <code>ABC123</code>
    <info>
      <language>zh-CN</language>
      <event>暴雨 &amp; 强对流</event>
      <urgency>Immediate</urgency>
      <severity>Severe</severity>
      <certainty>Likely</certainty>
      <headline>暴雨红色预警 &lt;升级&gt;</headline>
      <description>预计未来6小时降雨量将达100毫米以上</description>
      <instruction>停止集会、停课、停业</instruction>
      <cap:severityExtra xmlns:cap="urn:example:cap-ext" level="最高">特殊 &amp; 字符</cap:severityExtra>
      <area>
        <areaDesc>湛江市、茂名市</areaDesc>
        <geocode><valueName>Same</valueName><value>440800</value></geocode>
        <geocode><valueName>Same</valueName><value>440900</value></geocode>
      </area>
    </info>
  </alert>
  """

  @multi_info_xml ~s"""
  <?xml version="1.0" encoding="UTF-8"?>
  <alert xmlns="urn:oasis:names:tc:emergency:cap:1.2">
    <identifier>CN-C1</identifier>
    <sender>s@example.com</sender>
    <sent>2026-07-29T09:00:00+00:00</sent>
    <status>Actual</status>
    <msgType>Update</msgType>
    <scope>Public</scope>
    <references>s@example.com,CN-ORIG,2026-07-29T08:00:00+00:00</references>
    <info>
      <language>zh-CN</language>
      <event>暴雨</event>
      <urgency>Immediate</urgency>
      <severity>Severe</severity>
      <certainty>Likely</certainty>
      <headline>暴雨红色预警</headline>
      <area>
        <areaDesc>湛江市</areaDesc>
        <geocode><valueName>Same</valueName><value>440800</value></geocode>
      </area>
    </info>
    <info>
      <language>zh-CN</language>
      <event>暴雨</event>
      <urgency>Immediate</urgency>
      <severity>Extreme</severity>
      <certainty>Likely</certainty>
      <headline>暴雨红色预警（升级）</headline>
      <area>
        <areaDesc>茂名市</areaDesc>
        <geocode><valueName>Same</valueName><value>440900</value></geocode>
      </area>
    </info>
  </alert>
  """

  test "parses known CAP fields into an info segment" do
    assert {:ok, fields, _element} = CapXml.decode(@sample_xml)
    assert fields.identifier == "CN-20260729-GD-RAIN-001"
    assert fields.sender == "duty-officer@gd.example"
    assert fields.status == :actual
    assert fields.msg_type == :alert
    assert fields.scope == :public

    assert length(fields.infos) == 1
    info = hd(fields.infos)
    assert info.language == "zh-CN"
    assert info.urgency == :immediate
    assert info.severity == :severe
    assert info.certainty == :likely
    assert info.event == "暴雨 & 强对流"
    assert info.headline == "暴雨红色预警 <升级>"
    assert info.area_desc == "湛江市、茂名市"
    assert length(info.geocodes) == 2
    assert Enum.any?(info.geocodes, &(&1.value == "440800"))
    assert Enum.any?(info.geocodes, &(&1.value == "440900"))
  end

  test "preserves unknown extension elements including namespace and special chars" do
    assert {:ok, fields, _} = CapXml.decode(@sample_xml)
    alert_ext_names = fields.alert_extensions |> Enum.map(fn {n, _, _} -> n end)
    assert "code" in alert_ext_names

    info = hd(fields.infos)
    info_ext = info.info_extensions

    assert Enum.any?(info_ext, fn {name, attrs, children} ->
             name == "cap:severityExtra" and
               Map.get(attrs, "level") == "最高" and
               List.first(children) == "特殊 & 字符"
           end)
  end

  test "serialize then parse round-trips content and extensions" do
    assert {:ok, fields, _} = CapXml.decode(@sample_xml)
    xml = CapXml.encode(fields)

    assert {:ok, fields2, _} = CapXml.decode(xml)
    assert fields2.identifier == fields.identifier
    info = hd(fields2.infos)
    assert info.event == "暴雨 & 强对流"
    assert info.headline == "暴雨红色预警 <升级>"
    assert fields2.status == :actual
    assert fields2.msg_type == :alert
    assert info.urgency == :immediate
    assert info.severity == :severe
    assert info.certainty == :likely

    values = info.geocodes |> Enum.map(& &1.value) |> Enum.sort()
    assert values == ["440800", "440900"]

    serialized = CapXml.encode(fields2)
    assert serialized =~ "cap:severityExtra"
    assert serialized =~ "urn:example:cap-ext"
    assert serialized =~ "特殊 &amp; 字符"
    assert serialized =~ "暴雨红色预警 &lt;升级&gt;"
  end

  test "parses multiple info segments with independent severity per area" do
    assert {:ok, fields, _} = CapXml.decode(@multi_info_xml)
    assert fields.msg_type == :update
    assert fields.references =~ "CN-ORIG"
    assert length(fields.infos) == 2

    [first, second] = fields.infos
    assert first.severity == :severe
    assert hd(first.geocodes).value == "440800"
    assert second.severity == :extreme
    assert hd(second.geocodes).value == "440900"
  end

  test "multi-info round-trip preserves info-to-area correspondence and order" do
    assert {:ok, fields, _} = CapXml.decode(@multi_info_xml)
    xml = CapXml.encode(fields)
    assert {:ok, fields2, _} = CapXml.decode(xml)

    assert length(fields2.infos) == 2
    [first, second] = fields2.infos

    assert hd(first.geocodes).value == "440800"
    assert first.severity == :severe
    assert hd(second.geocodes).value == "440900"
    assert second.severity == :extreme

    assert length(String.split(xml, ~r(<info>))) == 3
  end

  test "rejects DOCTYPE declarations (XXE prevention)" do
    xml =
      ~s(<?xml version="1.0"?><!DOCTYPE foo [<!ENTITY xxe SYSTEM "file:///etc/passwd">]>) <>
        ~s(<alert xmlns="urn:oasis:names:tc:emergency:cap:1.2"><identifier>x</identifier></alert>)

    assert {:error, :doctype_or_entity_forbidden} = CapXml.parse(xml)
  end

  test "rejects ENTITY declarations" do
    xml =
      ~s(<?xml version="1.0"?><!DOCTYPE foo [<!ENTITY x "hi">]>) <>
        ~s(<alert xmlns="urn:oasis:names:tc:emergency:cap:1.2"><identifier>&x;</identifier></alert>)

    assert {:error, :doctype_or_entity_forbidden} = CapXml.parse(xml)
  end

  test "serializer does not use string concatenation for escaping" do
    fields = %{
      identifier: "X",
      sender: "s",
      sent: ~U[2026-07-29 08:00:00Z],
      status: :actual,
      msg_type: :alert,
      scope: :public,
      infos: [
        %{
          event: "a < b & c > d \"e\" 'f'",
          severity: :severe,
          geocodes: []
        }
      ]
    }

    xml = CapXml.encode(fields)
    assert xml =~ "a &lt; b &amp; c &gt; d"
    assert xml =~ "&quot;e&quot;"
    assert xml =~ ~s(&apos;f&apos;)
  end

  test "non-alert document returns error" do
    assert {:error, :not_an_alert} =
             CapXml.extract_cap({"foo", %{}, []})
  end
end
