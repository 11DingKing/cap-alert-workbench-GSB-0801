defmodule CapWorkbench.AlertsFixtures do
  @moduledoc """
  Test fixtures for building CAP alert messages through the public context.
  """
  alias CapWorkbench.Alerts

  @doc "Valid attrs for a brand new暴雨 draft, matching the seeded shape."
  def valid_attrs(overrides \\ %{}) do
    %{
      identifier: "CN-#{System.unique_integer([:positive])}-GD-RAIN-TST",
      sender: "cap@gd.gov.cn",
      sent_at: ~U[2026-07-29 08:00:00.000000Z],
      status: :actual,
      msg_type: :alert,
      scope: :public,
      language: "zh-CN",
      category: :met,
      event: "暴雨与强对流天气",
      urgency: :immediate,
      severity: :severe,
      certainty: :likely,
      headline: "暴雨红色预警",
      description: "预计未来6小时出现暴雨到大暴雨。",
      instruction: "转移低洼地带人员。",
      area_description: "揭阳市、茂名市",
      geocodes: ["440800", "440900"],
      effective_at: ~U[2026-07-29 08:00:00.000000Z],
      expires_at: ~U[2026-07-29 14:00:00.000000Z]
    }
    |> Map.merge(Map.new(overrides))
  end

  @doc "Creates a draft message and returns it (reloaded with versions)."
  def message_fixture(overrides \\ %{}) do
    {:ok, message} = Alerts.create_message(valid_attrs(overrides), "值班员")
    message
  end

  @doc "Creates a message and drives it all the way to :published."
  def published_message_fixture(overrides \\ %{}) do
    message = message_fixture(overrides)
    v = Alerts.latest_version(message)
    {:ok, message} = Alerts.submit_for_review(message, v, message.lock_version, "值班员")
    v = Alerts.latest_version(message)
    {:ok, message} = Alerts.review(message, v, :approve, "复核员", nil, message.lock_version)
    v = Alerts.latest_version(message)
    {:ok, message} = Alerts.publish(message, v, message.lock_version, "值班员")
    message
  end
end
