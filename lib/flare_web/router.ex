defmodule FlareWeb.Router do
  use FlareWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {FlareWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  # No :accepts plug here — SSE clients send `Accept: text/event-stream`,
  # which the :accepts plug would reject with 406.
  pipeline :sdk_api do
    plug FlareWeb.Plugs.SdkAuth
    plug FlareWeb.Plugs.RateLimit
  end

  pipeline :mgmt_api do
    plug :accepts, ["json"]
    plug FlareWeb.Plugs.ApiAuth
    plug FlareWeb.Plugs.RateLimit
  end

  scope "/", FlareWeb do
    pipe_through :browser

    get "/", PageController, :home
  end

  scope "/sdk", FlareWeb do
    pipe_through :sdk_api

    get "/ruleset", SdkController, :ruleset
    get "/stream", SdkController, :stream
  end

  scope "/api", FlareWeb.Api do
    pipe_through :mgmt_api

    get "/projects", ProjectController, :index
    post "/projects", ProjectController, :create
    post "/projects/:project_id/environments", EnvironmentController, :create
    get "/projects/:project_id/flags", FlagController, :index
    post "/projects/:project_id/flags", FlagController, :create
    patch "/flags/:id", FlagController, :update
    delete "/flags/:id", FlagController, :archive
    put "/flags/:flag_id/environments/:environment_id/settings", SettingController, :update
  end

  # Other scopes may use custom stacks.
  # scope "/api", FlareWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard in development
  if Application.compile_env(:flare, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: FlareWeb.Telemetry
    end
  end
end
