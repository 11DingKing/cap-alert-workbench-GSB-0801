alias CapAlertWorkbench.Cap
alias CapAlertWorkbench.Cap.Xml.Codec

# Idempotently create the initial required alert:
# CN-20260729-GD-RAIN-001
#   sent_at 2026-07-29T08:00:00Z
#   status Actual, msg_type Alert, scope Public, language zh-CN
#   urgency Immediate, severity Severe, certainty Likely
#   area codes 440800 (湛江市), 440900 (茂名市)

identifier = "CN-20260729-GD-RAIN-001"

case Cap.fetch_alert(identifier) do
  {:ok, _alert} ->
    IO.puts("Initial alert #{identifier} already exists, skipping seed.")

  {:error, :not_found} ->
    message =
      Codec.seed_message(
        identifier: identifier,
        sent_at: ~U[2026-07-29 08:00:00Z],
        status: :actual,
        msg_type: :alert,
        scope: :public,
        language: "zh-CN",
        urgency: :immediate,
        severity: :severe,
        certainty: :likely,
        area_codes: ["440800", "440900"]
      )

    attrs =
      message
      |> Map.from_struct()
      |> Map.put(:actor, "system:seed")
      |> Map.to_list()

    {:ok, _} = Cap.create_alert(attrs)
    IO.puts("Seeded initial CAP alert #{identifier}.")
end
