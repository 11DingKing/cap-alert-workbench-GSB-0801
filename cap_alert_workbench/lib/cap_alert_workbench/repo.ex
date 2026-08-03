defmodule CapAlertWorkbench.Repo do
  use Ecto.Repo,
    otp_app: :cap_alert_workbench,
    adapter: Ecto.Adapters.Postgres
end
