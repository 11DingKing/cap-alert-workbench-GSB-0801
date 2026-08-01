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
    plug :accepts, ["json", "xml"]
  end

  scope "/", CapAlertWorkbenchWeb do
    pipe_through :browser

    live "/", AlertIndexLive, :index
    live "/alerts/new", AlertNewLive, :new
    live "/alerts/:identifier", AlertLive, :show
    live "/alerts/:identifier/review/:version_id", ReviewLive, :review
    live "/alerts/:identifier/diff/:left/:right", VersionDiffLive, :diff
  end

  scope "/api", CapAlertWorkbenchWeb do
    pipe_through :api

    get "/alerts", API.AlertController, :index
    post "/alerts", API.AlertController, :create
    get "/alerts/:identifier", API.AlertController, :show
    get "/alerts/:identifier/versions", API.AlertController, :versions
    get "/alerts/:identifier/versions/:id", API.AlertController, :version
    get "/alerts/:identifier/versions/:id/cap", API.AlertController, :export_cap

    post "/alerts/:identifier/versions/:id/submit", API.AlertController, :submit
    post "/alerts/:identifier/versions/:id/review", API.AlertController, :review
    post "/alerts/:identifier/versions/:id/publish", API.AlertController, :publish
    post "/alerts/:identifier/corrections", API.AlertController, :create_correction
    post "/alerts/:identifier/cancellations", API.AlertController, :create_cancellation

    post "/import", API.AlertController, :import
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
