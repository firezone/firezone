defmodule FgHttpWeb.Router do
  @moduledoc """
  Main Application Router
  """

  use FgHttpWeb, :router

  # View emails locally in development
  if Mix.env() == :dev do
    forward "/sent_emails", Bamboo.SentEmailViewerPlug
  end

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, {FgHttpWeb.LayoutView, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", FgHttpWeb do
    pipe_through :browser

    live "/sign_in", SessionLive.New, :new
    live "/sign_up", UserLive.New, :new
    live "/account", AccountLive.Show, :show

    live "/password_reset", PasswordResetLive.New, :new
    live "/password_reset/:reset_token", PasswordResetLive.Edit, :edit

    live "/", DeviceLive.Index, :index
    live "/:id", DeviceLive.Show, :show

    get "/sign_in/:token", SessionController, :create
    post "/sign_out", SessionController, :delete
  end
end
