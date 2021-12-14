defmodule FzHttpWeb.Router do
  @moduledoc """
  Main Application Router
  """

  use FzHttpWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, {FzHttpWeb.LayoutView, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", FzHttpWeb do
    pipe_through :browser

    get "/", DeviceController, :index
    get "/devices/:id/dl", DeviceController, :download_config
    resources "/session", SessionController, only: [:new, :create, :delete], singleton: true

    live "/users", UserLive.Index, :index
    live "/users/new", UserLive.Index, :new
    live "/users/:id", UserLive.Show, :show
    live "/users/:id/edit", UserLive.Show, :edit

    live "/rules", RuleLive.Index, :index

    live "/devices", DeviceLive.Index, :index
    live "/devices/:id", DeviceLive.Show, :show
    live "/devices/:id/edit", DeviceLive.Show, :edit

    live "/settings/default", SettingLive.Default, :default

    live "/settings/security", SettingLive.Security, :security

    live "/settings/account", AccountLive.Show, :show
    live "/settings/account/edit", AccountLive.Show, :edit

    live "/diagnostics/connectivity_checks", ConnectivityCheckLive.Index, :index

    get "/sign_in/:token", SessionController, :create
    delete "/user", UserController, :delete
  end
end
