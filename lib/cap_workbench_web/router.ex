defmodule CapWorkbenchWeb.Router do
  use CapWorkbenchWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {CapWorkbenchWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", CapWorkbenchWeb do
    pipe_through :browser

    get "/", PageController, :home

    live "/messages", MessageLive.Index, :index
    live "/messages/new", MessageLive.Index, :new
    live "/messages/:id", MessageLive.Show, :show
  end

  scope "/api", CapWorkbenchWeb.Api do
    pipe_through :api

    get "/messages", MessageController, :index
    post "/messages", MessageController, :create
    get "/messages/:id", MessageController, :show
    get "/messages/:id/export", MessageController, :export
    post "/messages/import", MessageController, :import
    post "/messages/:id/versions", MessageController, :save_version
    post "/messages/:id/submit", MessageController, :submit
    post "/messages/:id/review", MessageController, :review
    post "/messages/:id/publish", MessageController, :publish
    post "/messages/:id/correction", MessageController, :correction
    post "/messages/:id/cancellation", MessageController, :cancellation
  end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:cap_workbench, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: CapWorkbenchWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
