defmodule CapAlertWorkbench.Cap.XmlTest do
  use ExUnit.Case, async: true

  alias CapAlertWorkbench.Cap.{Document, Info, Xml}

  @prefixed_xml """
  <?xml version="1.0" encoding="UTF-8"?>
  <cap:alert xmlns:cap="urn:oasis:names:tc:emergency:cap:1.2">
    <cap:identifier>CN-20260729-GD-RAIN-001</cap:identifier>
    <cap:sender>gd-moji@weather.gd.gov.cn</cap:sender>
    <cap:sent>2026-07-29T08:00:00+08:00</cap:sent>
    <cap:status>Actual</cap:status>
    <cap:msgType>Alert</cap:msgType>
    <cap:scope>Public</cap:scope>
    <cap:info>
      <cap:language>zh-CN</cap:language>
      <cap:category>Met</cap:category>
      <cap:event>暴雨 &amp; 强对流 &lt;红色&gt; &quot;预警&quot; &apos;台风&apos;</cap:event>
      <cap:urgency>Immediate</cap:urgency>
      <cap:severity>Severe</cap:severity>
      <cap:certainty>Likely</cap:certainty>
      <cap:headline>注意防御 &lt;&gt; 强对流</cap:headline>
      <cap:description>含有 &amp; 特殊字符与中文 emoji ⛈️ 的描述</cap:description>
      <cap:instruction>1. 转移；2. 停工</cap:instruction>
      <cap:area>
        <cap:areaDesc>湛江市、茂名市</cap:areaDesc>
        <cap:geocode><cap:valueName>region</cap:valueName><cap:value>440800</cap:value></cap:geocode>
        <cap:geocode><cap:valueName>region</cap:valueName><cap:value>440900</cap:value></cap:geocode>
      </cap:area>
      <vendor:extension xmlns:vendor="http://vendor.example/cap-ext" vendor:channel="dmos">
        <vendor:payload level="3">自定义 &amp; 扩展内容</vendor:payload>
      </vendor:extension>
    </cap:info>
    <x:afterInfo xmlns:x="http://x.example" keep="yes"><x:node>根级扩展</x:node></x:afterInfo>
  </cap:alert>
  """

  @multi_info_xml """
  <?xml version="1.0" encoding="UTF-8"?>
  <alert xmlns="urn:oasis:names:tc:emergency:cap:1.2">
    <identifier>CN-20260729-GD-RAIN-001-C1</identifier>
    <sender>gd-moji@weather.gd.gov.cn</sender>
    <sent>2026-08-01T12:00:00+08:00</sent>
    <status>Actual</status>
    <msgType>Update</msgType>
    <scope>Public</scope>
    <references>gd-moji@weather.gd.gov.cn,CN-20260729-GD-RAIN-001,2026-08-01T11:00:00+08:00</references>
    <info>
      <language>zh-CN</language>
      <category>Met</category>
      <event>暴雨及强对流天气</event>
      <urgency>Immediate</urgency>
      <severity>Severe</severity>
      <certainty>Likely</certainty>
      <headline>湛江维持暴雨红色预警</headline>
      <description>湛江市维持 Severe &lt;不变&gt;</description>
      <area>
        <areaDesc>湛江市</areaDesc>
        <geocode><valueName>region</valueName><value>440800</value></geocode>
      </area>
    </info>
    <info>
      <language>zh-CN</language>
      <category>Met</category>
      <event>暴雨及强对流天气</event>
      <urgency>Immediate</urgency>
      <severity>Extreme</severity>
      <certainty>Likely</certainty>
      <headline>茂名升级为暴雨红色预警（极端）</headline>
      <description>茂名市升级为 Extreme &amp; 特大暴雨</description>
      <area>
        <areaDesc>茂名市</areaDesc>
        <geocode><valueName>region</valueName><value>440900</value></geocode>
      </area>
      <vendor:ext xmlns:vendor="http://vendor.example/cap-ext" vendor:level="5">极端扩展&amp;保留</vendor:ext>
    </info>
  </alert>
  """

  test "解析带命名空间前缀的 CAP XML" do
    assert {:ok, doc} = Xml.parse(@prefixed_xml)
    assert doc.identifier == "CN-20260729-GD-RAIN-001"
    assert doc.status == :actual
    assert doc.msg_type == :alert
    assert doc.scope == :public

    assert [info] = doc.infos
    assert info.urgency == :immediate
    assert info.severity == :severe
    assert info.certainty == :likely
    assert info.language == "zh-CN"

    assert [%{geocodes: geocodes}] = info.areas
    assert Enum.map(geocodes, & &1.value) == ["440800", "440900"]
  end

  test "特殊字符被正确解码，round-trip 后逐字段相等" do
    assert {:ok, doc} = Xml.parse(@prefixed_xml)
    [info] = doc.infos
    assert info.event == ~s(暴雨 & 强对流 <红色> "预警" '台风')
    assert info.description =~ "⛈️"

    xml = Xml.serialize(doc)
    assert {:ok, doc2} = Xml.parse(xml)
    assert doc2 == doc
  end

  test "多 info 段：地区与严重度对应关系 round-trip 完整" do
    assert {:ok, doc} = Xml.parse(@multi_info_xml)
    assert doc.identifier == "CN-20260729-GD-RAIN-001-C1"
    assert doc.msg_type == :update
    assert length(doc.infos) == 2

    [info_440800, info_440900] = doc.infos
    assert Info.geocodes(info_440800) == ["440800"]
    assert info_440800.severity == :severe
    assert info_440800.headline == "湛江维持暴雨红色预警"

    assert Info.geocodes(info_440900) == ["440900"]
    assert info_440900.severity == :extreme
    assert length(info_440900.extensions) == 1

    assert [%{identifier: "CN-20260729-GD-RAIN-001", sent: "2026-08-01T11:00:00+08:00"}] =
             doc.references

    xml = Xml.serialize(doc)
    assert {:ok, doc2} = Xml.parse(xml)
    assert doc2 == doc

    [re_440800, re_440900] = doc2.infos
    assert Info.geocodes(re_440800) == ["440800"]
    assert re_440800.severity == :severe
    assert Info.geocodes(re_440900) == ["440900"]
    assert re_440900.severity == :extreme
  end

  test "序列化输出由构建库转义，特殊字符不会被原样注入" do
    doc = %Document{
      identifier: "T-1",
      sender: "s<script>alert(1)</script>",
      sent: "2026-07-29T08:00:00+08:00",
      infos: [
        %Info{
          event: "a & b <c> \"d\" 'e'",
          description: "描述 & <script>"
        }
      ]
    }

    xml = Xml.serialize(doc)
    refute xml =~ "<script>"
    assert xml =~ "&lt;script&gt;"
    assert xml =~ "a &amp; b &lt;c&gt;"

    assert {:ok, doc2} = Xml.parse(xml)
    [info] = doc2.infos
    assert info.event == "a & b <c> \"d\" 'e'"
    assert info.description == "描述 & <script>"
  end

  test "未知扩展字段（含嵌套与属性）在 round-trip 中原样保留" do
    assert {:ok, doc} = Xml.parse(@prefixed_xml)
    [info] = doc.infos
    assert length(info.extensions) == 1
    assert length(doc.extensions) == 1

    xml = Xml.serialize(doc)
    assert xml =~ "vendor:extension"
    assert xml =~ "自定义 &amp; 扩展内容"
    assert xml =~ "根级扩展"

    assert {:ok, doc2} = Xml.parse(xml)
    [info2] = doc2.infos
    assert info2.extensions == info.extensions
    assert doc2.extensions == doc.extensions
  end

  test "references 多组引用 round-trip" do
    doc = %Document{
      identifier: "CN-2",
      sender: "s",
      sent: "2026-07-29T09:00:00+08:00",
      msg_type: :update,
      infos: [%Info{event: "更正"}],
      references: [
        %{sender: "s", identifier: "CN-1", sent: "2026-07-29T08:00:00+08:00"},
        %{sender: "s", identifier: "CN-0", sent: "2026-07-28T08:00:00+08:00"}
      ]
    }

    xml = Xml.serialize(doc)

    assert xml =~
             "<references>s,CN-1,2026-07-29T08:00:00+08:00 s,CN-0,2026-07-28T08:00:00+08:00</references>"

    assert {:ok, doc2} = Xml.parse(xml)
    assert doc2.references == doc.references
  end

  test "DOCTYPE / 外部实体声明一律拒绝，不访问任何外部资源" do
    xxe = """
    <?xml version="1.0"?>
    <!DOCTYPE alert [<!ENTITY xxe SYSTEM "file:///etc/passwd">]>
    <alert xmlns="urn:oasis:names:tc:emergency:cap:1.2">
      <identifier>&xxe;</identifier><sender>s</sender>
      <sent>2026-07-29T08:00:00+08:00</sent>
      <status>Actual</status><msgType>Alert</msgType><scope>Public</scope>
      <info><urgency>Immediate</urgency><severity>Severe</severity>
      <certainty>Likely</certainty><category>Met</category></info>
    </alert>
    """

    assert {:error, :doctype_forbidden} = Xml.parse(xxe)

    xxe_remote = String.replace(xxe, "file:///etc/passwd", "http://evil.example/xxe")
    assert {:error, :doctype_forbidden} = Xml.parse(xxe_remote)
  end

  test "畸形 XML 返回错误而不是异常" do
    assert {:error, {:malformed_xml, _}} = Xml.parse("<alert><unclosed>")
    assert {:error, {:malformed_xml, _}} = Xml.parse("not xml at all <<<")
  end

  test "未知枚举值严格报错" do
    xml = """
    <alert xmlns="urn:oasis:names:tc:emergency:cap:1.2">
      <identifier>X</identifier><sender>s</sender>
      <sent>2026-07-29T08:00:00+08:00</sent>
      <status>Actual</status><msgType>Alert</msgType><scope>Public</scope>
      <info><urgency>Someday</urgency><severity>Severe</severity>
      <certainty>Likely</certainty><category>Met</category></info>
    </alert>
    """

    assert {:error, {:unknown_enum, :urgency, "Someday"}} = Xml.parse(xml)
  end

  test "非 alert 根元素报错" do
    assert {:error, {:unexpected_root, "feed"}} = Xml.parse("<feed/>")
  end

  test "Document 校验：必填字段、日期格式与 info 段要求" do
    assert :ok =
             Document.validate(%Document{
               identifier: "X",
               sender: "s",
               sent: "2026-07-29T08:00:00+08:00",
               infos: [%Info{event: "e"}]
             })

    assert {:error, errors} = Document.validate(%Document{})
    assert Keyword.has_key?(errors, :identifier)
    assert Keyword.has_key?(errors, :infos)

    assert {:error, [sent: _]} =
             Document.validate(%Document{
               identifier: "X",
               sender: "s",
               sent: "not-a-date",
               infos: [%Info{event: "e"}]
             })

    assert {:error, [{{:info, 0, :event}, _}]} =
             Document.validate(%Document{
               identifier: "X",
               sender: "s",
               sent: "2026-07-29T08:00:00+08:00",
               infos: [%Info{event: nil}]
             })
  end

  test "Document <-> jsonb map round-trip（含多 info 与扩展）" do
    assert {:ok, doc} = Xml.parse(@multi_info_xml)
    map = Document.to_map(doc)
    assert {:ok, restored} = Document.from_map(map)
    assert restored == doc
  end
end
