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

  test "parses known CAP fields" do
    assert {:ok, fields, _element} = CapXml.decode(@sample_xml)
    assert fields.identifier == "CN-20260729-GD-RAIN-001"
    assert fields.sender == "duty-officer@gd.example"
    assert fields.status == :actual
    assert fields.msg_type == :alert
    assert fields.scope == :public
    assert fields.language == "zh-CN"
    assert fields.urgency == :immediate
    assert fields.severity == :severe
    assert fields.certainty == :likely
    assert fields.event == "暴雨 & 强对流"
    assert fields.headline == "暴雨红色预警 <升级>"
    assert fields.area_desc == "湛江市、茂名市"
    assert length(fields.geocodes) == 2
    assert Enum.any?(fields.geocodes, &(&1.value == "440800"))
    assert Enum.any?(fields.geocodes, &(&1.value == "440900"))
  end

  test "preserves unknown extension elements including namespace and special chars" do
    assert {:ok, fields, _} = CapXml.decode(@sample_xml)
    # <code> at alert level is unknown to our extractor and should be preserved
    alert_ext_names = fields.alert_extensions |> Enum.map(fn {n, _, _} -> n end)
    assert "code" in alert_ext_names

    # namespace-qualified extension under <info>
    info_ext = fields.info_extensions

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
    assert fields2.event == "暴雨 & 强对流"
    assert fields2.headline == "暴雨红色预警 <升级>"
    assert fields2.status == :actual
    assert fields2.msg_type == :alert
    assert fields2.urgency == :immediate
    assert fields2.severity == :severe
    assert fields2.certainty == :likely

    # geocodes survive
    values = fields2.geocodes |> Enum.map(& &1.value) |> Enum.sort()
    assert values == ["440800", "440900"]

    # the namespace extension survives re-serialization
    serialized = CapXml.encode(fields2)
    assert serialized =~ "cap:severityExtra"
    assert serialized =~ "urn:example:cap-ext"
    assert serialized =~ "特殊 &amp; 字符"
    assert serialized =~ "暴雨红色预警 &lt;升级&gt;"
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
      event: "a < b & c > d \"e\" 'f'",
      geocodes: []
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
