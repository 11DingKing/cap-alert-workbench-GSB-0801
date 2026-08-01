defmodule CapWorkbench.Repo do
  use Ecto.Repo,
    otp_app: :cap_workbench,
    adapter: Ecto.Adapters.Postgres
end
