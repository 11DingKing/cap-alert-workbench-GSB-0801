# Script for populating the database.
#
# Run with: `mix run priv/repo/seeds.exs`

alias CapAlertWorkbench.CapAlert

identifier = "CN-20260729-GD-RAIN-001"

attrs = %{
  "identifier" => identifier,
  "sender" => "duty-officer@gd.example",
  "sent" => ~U[2026-07-29 08:00:00Z],
  "status" => "actual",
  "msg_type" => "alert",
  "scope" => "public",
  "language" => "zh-CN",
  "event" => "暴雨",
  "headline" => "暴雨红色预警",
  "description" => "预计未来6小时内，湛江、茂名等地降雨量将达100毫米以上，并伴有强对流天气。",
  "instruction" => "停止集会、停课、停业；做好山洪、滑坡等灾害的防御准备。",
  "urgency" => "immediate",
  "severity" => "severe",
  "certainty" => "likely",
  "area_desc" => "湛江市、茂名市",
  "geocodes" => %{
    "0" => %{"value_name" => "Same", "value" => "440800"},
    "1" => %{"value_name" => "Same", "value" => "440900"}
  }
}

if CapAlert.get_alert(identifier) do
  IO.puts("Alert #{identifier} already exists, skipping seed.")
else
  {:ok, %{alert: alert, version: version}} = CapAlert.create_alert(attrs, "seed")

  IO.puts("""

  Seeded initial CAP alert:
    identifier: #{alert.identifier}
    version:    v#{version.version_number}
    state:      #{version.workflow_state}
    event:      #{version.event}
    severity:   #{version.severity}
    geocodes:   #{inspect(Enum.map(version.geocodes, & &1.value))}

  Open the workbench:
    http://localhost:4000/alerts/#{alert.identifier}
  """)
end
