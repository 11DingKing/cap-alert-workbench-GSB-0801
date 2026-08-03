defmodule CapAlertWorkbench.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        CapAlertWorkbenchWeb.Telemetry,
        CapAlertWorkbench.Repo,
        {DNSCluster,
         query: Application.get_env(:cap_alert_workbench, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: CapAlertWorkbench.PubSub}
      ] ++
        maybe_outbox_dispatcher() ++
        [
          # Start to serve requests, typically the last entry
          CapAlertWorkbenchWeb.Endpoint
        ]

    # See https://elixir.hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: CapAlertWorkbench.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # The outbox dispatcher polls the database on an interval. In test the SQL
  # sandbox owns the connection per-test, so a long-lived polling process would
  # hit ownership errors; it is disabled there.
  defp maybe_outbox_dispatcher do
    if Application.get_env(:cap_alert_workbench, :start_outbox_dispatcher, true) do
      [CapAlertWorkbench.Cap.OutboxDispatcher]
    else
      []
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    CapAlertWorkbenchWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
