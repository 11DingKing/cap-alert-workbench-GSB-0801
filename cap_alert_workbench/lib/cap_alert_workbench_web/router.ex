defmodule CapAlertWorkbenchWeb.Router do
  use CapAlertWorkbenchWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {CapAlertWorkbenchWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", CapAlertWorkbenchWeb do
    pipe_through :browser

    live "/", AlertLive.Index, :index
    live "/alerts", AlertLive.Index, :index
    live "/alerts/:id", AlertLive.Show, :show
    live "/alerts/:id/versions/:a/:b", AlertLive.Show, :diff
  end

  scope "/api", CapAlertWorkbenchWeb do
    pipe_through :api

    get "/alerts", Api.AlertController, :index
    post "/alerts", Api.AlertController, :create
    get "/alerts/:id", Api.AlertController, :show
    put "/alerts/:id/draft", Api.AlertController, :update_draft
    post "/alerts/:id/submit", Api.AlertController, :submit
    post "/alerts/:id/review", Api.AlertController, :review
    post "/alerts/:id/publish", Api.AlertController, :publish
    post "/alerts/:id/correct", Api.AlertController, :correct
    post "/alerts/:id/cancel", Api.AlertController, :cancel
    get "/alerts/:id/versions", Api.AlertController, :versions
    get "/alerts/:id/versions/:version/xml", Api.AlertController, :version_xml
    get "/alerts/:id/audit", Api.AlertController, :audit
    post "/alerts/import", Api.AlertController, :import_xml
  end

  # Enable LiveDashboard in development
  if Application.compile_env(:cap_alert_workbench, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: CapAlertWorkbenchWeb.Telemetry
    end
  end
end
