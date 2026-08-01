# 初始种子数据：暴雨 / 强对流公共预警草稿
#
#     mix run priv/repo/seeds.exs
#
# 幂等：identifier 已存在时跳过。

alias CapAlertWorkbench.Alerts
alias CapAlertWorkbench.Cap.{Document, Info}
alias CapAlertWorkbench.Repo

identifier = "CN-20260729-GD-RAIN-001"

case Repo.get_by(Alerts.Stream, identifier: identifier) do
  nil ->
    doc = %Document{
      identifier: identifier,
      sender: "gd-moji@weather.gd.gov.cn",
      sent: "2026-07-29T08:00:00+08:00",
      status: :actual,
      msg_type: :alert,
      scope: :public,
      infos: [
        %Info{
          language: "zh-CN",
          category: :met,
          event: "暴雨及强对流天气",
          urgency: :immediate,
          severity: :severe,
          certainty: :likely,
          headline: "暴雨红色预警：湛江、茂名将有特大暴雨并伴有强对流",
          description: """
          预计 7 月 29 日夜间至 30 日，湛江市、茂名市有大暴雨到特大暴雨，
          局地累计雨量可达 250 毫米以上，并伴有 8-10 级雷暴大风、短时强降水
          等强对流天气，城乡积涝、山洪、地质灾害风险高。
          """,
          instruction: """
          1. 低洼易涝区、危旧房屋人员立即转移；
          2. 停止户外作业、海上作业船只回港避风；
          3. 学校视情停课，交通部门做好积水路段管制；
          4. 各级三防责任人 24 小时值守，遇险立即上报。
          """,
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
      ]
    }

    {:ok, %{stream: stream, version: version}} =
      Alerts.create_stream(
        %{
          identifier: identifier,
          sender: doc.sender,
          payload: Document.to_map(doc)
        },
        "seed"
      )

    IO.puts("已创建初始预警 #{stream.identifier}（草稿 v#{version.version_number}，编辑中）")

  _existing ->
    IO.puts("初始预警 #{identifier} 已存在，跳过")
end
