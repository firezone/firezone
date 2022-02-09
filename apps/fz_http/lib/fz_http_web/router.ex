defmodule FzHttpWeb.Router do
  @moduledoc """
  Main Application Router
  """

  use FzHttpWeb, :router

  @root_rate_limit [rate_limit: {"root", 10_000, 50}, by: :ip]

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, {FzHttpWeb.LayoutView, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers

    # Limit total requests to 20 per every 10 seconds
    # XXX: Make this configurable
    plug Hammer.Plug, @root_rate_limit
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", FzHttpWeb do
    pipe_through :browser

    resources "/session", SessionController, only: [:new, :create, :delete], singleton: true

    live "/users", UserLive.Index, :index
    live "/users/new", UserLive.Index, :new
    live "/users/:id", UserLive.Show, :show
    live "/users/:id/edit", UserLive.Show, :edit

    live "/rules", RuleLive.Index, :index

    live "/devices", DeviceLive.Index, :index
    live "/devices/new", DeviceLive.Index, :new
    live "/devices/:id", DeviceLive.Show, :show
    live "/devices/:id/edit", DeviceLive.Show, :edit
    get "/devices/:id/dl", DeviceController, :download_config
    get "/device_config/:config_token", DeviceController, :config
    get "/device_config/:config_token/dl", DeviceController, :download_shared_config

    live "/settings/site", SettingLive.Site, :show
    live "/settings/security", SettingLive.Security, :show
    live "/settings/account", SettingLive.Account, :show
    live "/settings/account/edit", SettingLive.Account, :edit

    live "/diagnostics/connectivity_checks", ConnectivityCheckLive.Index, :index

    get "/sign_in/:token", SessionController, :create
    delete "/user", UserController, :delete
    get "/user", UserController, :show

    get "/", RootController, :index
  end
end
