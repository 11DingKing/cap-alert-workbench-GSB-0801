# Script for populating the database. Run with:
#
#     mix run priv/repo/seeds.exs
#
# Idempotent: re-running will not duplicate the initial message.

import Ecto.Query

alias CapWorkbench.Alerts
alias CapWorkbench.Cap.AlertMessage
alias CapWorkbench.Repo

identifier = "CN-20260729-GD-RAIN-001"

case Repo.one(from m in AlertMessage, where: m.identifier == ^identifier) do
  nil ->
    {:ok, message} =
      Alerts.create_message(
        %{
          # --- Stable CAP envelope identity ---
          identifier: identifier,
          sender: "cap@gd.gov.cn",
          sent_at: ~U[2026-07-29 08:00:00.000000Z],
          status: :actual,
          msg_type: :alert,
          scope: :public,
          # --- First immutable draft version content ---
          language: "zh-CN",
          category: :met,
          event: "暴雨与强对流天气",
          urgency: :immediate,
          severity: :severe,
          certainty: :likely,
          headline: "暴雨红色预警及强对流处置建议",
          description:
            "受强降雨云团影响，预计未来 6 小时内我市部分地区将出现暴雨到大暴雨，" <>
              "并伴有短时强降水、雷暴大风等强对流天气。请注意防范城乡积涝、山洪及地质灾害。",
          instruction:
            "1. 停止户外作业与集会；2. 转移低洼地带与地质灾害隐患点人员；" <>
              "3. 加强排水调度，做好交通管制与抢险准备。",
          area_description: "广东省揭阳市、茂名市",
          # 440800 = 湛江市辖区示例编码，440900 = 茂名市（地级市行政区划编码）
          geocodes: ["440800", "440900"],
          effective_at: ~U[2026-07-29 08:00:00.000000Z],
          onset_at: ~U[2026-07-29 08:30:00.000000Z],
          expires_at: ~U[2026-07-29 14:00:00.000000Z]
        },
        "值班员-01"
      )

    IO.puts("Seeded initial alert message #{message.identifier} (#{message.id})")

  %AlertMessage{} = existing ->
    IO.puts("Alert message #{existing.identifier} already present (#{existing.id}); skipping.")
end
