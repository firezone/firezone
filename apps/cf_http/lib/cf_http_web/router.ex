defmodule CfHttpWeb.Router do
  @moduledoc """
  Main Application Router
  """

  use CfHttpWeb, :router

  # View emails locally in development
  if Mix.env() == :dev do
    forward "/sent_emails", Bamboo.SentEmailViewerPlug
  end

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, {CfHttpWeb.LayoutView, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", CfHttpWeb do
    pipe_through :browser

    live "/sign_in", SessionLive.New, :new
    live "/sign_up", UserLive.New, :new
    live "/account", AccountLive.Show, :show
    live "/account/edit", AccountLive.Show, :edit

    live "/password_reset", PasswordResetLive.New, :new
    live "/password_reset/:reset_token", PasswordResetLive.Edit, :edit

    live "/", RootLive.Index, :index

    live "/devices", DeviceLive.Index, :index
    live "/devices/:id", DeviceLive.Show, :show
    live "/devices/:id/edit", DeviceLive.Show, :edit

    get "/sign_in/:token", SessionController, :create
    post "/sign_out", SessionController, :delete
    delete "/user", UserController, :delete
  end
end
