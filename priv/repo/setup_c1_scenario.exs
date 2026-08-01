# 把 dev 库铺设到「初始消息已发布 + C1 更正草稿（440800 Severe / 440900 Extreme）」状态
#
#     mix run priv/repo/setup_c1_scenario.exs

alias CapAlertWorkbench.Alerts
alias CapAlertWorkbench.Repo

identifier = "CN-20260729-GD-RAIN-001"
stream = Repo.get_by!(Alerts.Stream, identifier: identifier)
{:ok, detail} = Alerts.get_stream_detail(stream.id)

case detail.stream.state do
  :drafting ->
    [v1] = detail.versions

    {:ok, v} = Alerts.submit_for_review(v1.id, v1.lock_version, "duty-officer")
    {:ok, v} = Alerts.decide_review(v.id, :approved, "首轮发布", "reviewer-1", v.lock_version)
    {:ok, _published} = Alerts.publish(v.id, "duty-officer")
    IO.puts("首轮已发布")

    {:ok, correction} = Alerts.start_correction(stream.id, "duty-officer")
    IO.puts("已创建更正草稿 #{correction.payload["identifier"]}")

    base_info = hd(correction.payload["infos"])

    # 440800 除地区拆分外与基线完全一致（差异页应显示「未变化」）
    info_440800 =
      base_info
      |> Map.put("areas", [
        %{
          "area_desc" => "湛江市",
          "geocodes" => [%{"value_name" => "region", "value" => "440800"}]
        }
      ])

    info_440900 =
      base_info
      |> Map.put("severity", "Extreme")
      |> Map.put("headline", "茂名升级为暴雨红色预警（极端）")
      |> Map.put("description", "茂名市雨势进一步增强，局地特大暴雨，强对流剧烈")
      |> Map.put("areas", [
        %{
          "area_desc" => "茂名市",
          "geocodes" => [%{"value_name" => "region", "value" => "440900"}]
        }
      ])

    payload = Map.put(correction.payload, "infos", [info_440800, info_440900])

    {:ok, updated} =
      Alerts.update_draft(correction.id, %{payload: payload}, correction.lock_version, "duty-officer")

    [i1, i2] = updated.payload["infos"]
    IO.puts("C1 草稿已更新：#{i1["severity"]}@440800 / #{i2["severity"]}@440900，处于编辑中")

  state ->
    IO.puts("消息流当前状态为 #{state}，跳过铺设（如需重来请 mix ecto.reset 后重跑种子与本脚本）")
end
