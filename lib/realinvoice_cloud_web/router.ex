defmodule RealinvoiceCloudWeb.Router do
  use RealinvoiceCloudWeb, :router

  import RealinvoiceCloudWeb.UserAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {RealinvoiceCloudWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_scope_for_user
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  # Other scopes may use custom stacks.
  # scope "/api", RealinvoiceCloudWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:realinvoice_cloud, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: RealinvoiceCloudWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end

  ## Authentication routes

  scope "/", RealinvoiceCloudWeb do
    pipe_through [:browser, :require_authenticated_user]

    live_session :require_authenticated_user,
      on_mount: [{RealinvoiceCloudWeb.UserAuth, :require_authenticated}] do
      live "/", DashboardLive, :dashboard
      live "/invoices", SectionLive, :invoices
      live "/customers", SectionLive, :customers
      live "/items", SectionLive, :items
      live "/nodes", SectionLive, :nodes
      live "/settings", SettingsLive, :settings

      live "/users/settings", UserLive.Settings, :edit
      live "/users/settings/confirm-email/:token", UserLive.Settings, :confirm_email
    end

    post "/users/update-password", UserSessionController, :update_password
  end

  scope "/", RealinvoiceCloudWeb do
    pipe_through [:browser]

    live_session :current_user,
      on_mount: [{RealinvoiceCloudWeb.UserAuth, :mount_current_scope}] do
      # No "/users/register" route: this is an internal admin tool, so accounts
      # are provisioned with priv/repo/seeds.exs rather than self-service.
      live "/users/log-in", UserLive.Login, :new
      live "/users/log-in/:token", UserLive.Confirmation, :new
    end

    post "/users/log-in", UserSessionController, :create
    delete "/users/log-out", UserSessionController, :delete
  end
end
