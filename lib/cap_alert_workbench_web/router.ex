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

  # 原始 XML 导入：不走 JSON body parser
  pipeline :api_xml do
    plug :accepts, ["xml"]
  end

  scope "/", CapAlertWorkbenchWeb do
    pipe_through :browser

    live "/", WorkbenchLive, :index
    live "/streams/:stream_id", WorkbenchLive, :show
  end

  scope "/api", CapAlertWorkbenchWeb.Api do
    pipe_through :api

    get "/streams", MessageController, :index
    get "/streams/:id", MessageController, :show
    post "/streams/:id/corrections", MessageController, :start_correction
    post "/streams/:id/cancellations", MessageController, :start_cancellation

    get "/versions/:id/cap.xml", MessageController, :export_xml
    post "/versions/:id/draft", MessageController, :update_draft
    post "/versions/:id/submit-review", MessageController, :submit_review
    post "/versions/:id/review", MessageController, :review
    post "/versions/:id/publish", MessageController, :publish
  end

  scope "/api", CapAlertWorkbenchWeb.Api do
    pipe_through :api_xml

    post "/streams/import", MessageController, :import_xml
  end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:cap_alert_workbench, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: CapAlertWorkbenchWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
