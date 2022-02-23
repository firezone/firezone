defmodule FzHttpWeb.Router do
  @moduledoc """
  Main Application Router
  """

  use FzHttpWeb, :router

  # Limit total requests to 20 per every 10 seconds
  @root_rate_limit [rate_limit: {"root", 10_000, 50}, by: :ip]

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, {FzHttpWeb.LayoutView, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers

    # XXX: Make this configurable
    plug Hammer.Plug, @root_rate_limit
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", FzHttpWeb do
    pipe_through :browser

    # Unprivileged routes
    live_session(
      :unprivileged,
      on_mount: {FzHttpWeb.LiveAuth, :unprivileged},
      root_layout: {FzHttpWeb.LayoutView, :unprivileged}
    ) do
      live "/user_devices", DeviceLive.Unprivileged.Index, :index
      live "/user_devices/new", DeviceLive.Unprivileged.Index, :new
      live "/user_devices/:id", DeviceLive.Unprivileged.Show, :show
    end

    # Admin routes
    live_session(
      :admin,
      on_mount: {FzHttpWeb.LiveAuth, :admin},
      root_layout: {FzHttpWeb.LayoutView, :admin}
    ) do
      live "/users", UserLive.Index, :index
      live "/users/new", UserLive.Index, :new
      live "/users/:id", UserLive.Show, :show
      live "/users/:id/edit", UserLive.Show, :edit
      live "/users/:id/new_device", UserLive.Show, :new_device
      live "/rules", RuleLive.Index, :index
      live "/devices", DeviceLive.Admin.Index, :index
      live "/devices/:id", DeviceLive.Admin.Show, :show
      live "/devices/:id/edit", DeviceLive.Admin.Show, :edit
      live "/settings/site", SettingLive.Site, :show
      live "/settings/security", SettingLive.Security, :show
      live "/settings/account", SettingLive.Account, :show
      live "/settings/account/edit", SettingLive.Account, :edit
      live "/diagnostics/connectivity_checks", ConnectivityCheckLive.Index, :index
    end

    # Synchronous routes
    resources "/session", SessionController, only: [:new, :create, :delete], singleton: true
    get "/sign_in/:token", SessionController, :create
    delete "/user", UserController, :delete
    get "/user", UserController, :show
    get "/", RootController, :index
  end
end
