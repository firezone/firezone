defmodule FzHttpWeb.Router do
  @moduledoc """
  Main Application Router
  """

  use FzHttpWeb, :router

  # View emails locally in development
  if Mix.env() == :dev do
    forward "/sent_emails", Bamboo.SentEmailViewerPlug
  end

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
    get "/devices", DeviceController, :index
    get "/rules", RuleController, :index
    get "/session/new", SessionController, :new

    # live "/sign_in", SessionLive.New, :new
    # live "/sign_up", UserLive.New, :new
    # live "/account", AccountLive.Show, :show
    # live "/account/edit", AccountLive.Show, :edit

    # live "/rules", RuleLive.Index, :index

    # live "/devices", DeviceLive.Index, :index
    # live "/devices/:id", DeviceLive.Show, :show
    # live "/devices/:id/edit", DeviceLive.Show, :edit

    get "/sign_in/:token", SessionController, :create
    post "/sign_out", SessionController, :delete
    delete "/user", UserController, :delete
  end
end
