defmodule FgHttpWeb.Router do
  @moduledoc """
  Main Application Router
  """

  alias FgHttpWeb.{BlacklistLive, DeviceDetailsLive, WhitelistLive}
  use FgHttpWeb, :router

  # View emails locally in development
  if Mix.env() == :dev do
    forward "/sent_emails", Bamboo.SentEmailViewerPlug
  end

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", FgHttpWeb do
    pipe_through :browser
    live "/live/device_details", DeviceDetailsLive
    live "/live/whitelist", WhitelistLive
    live "/live/blacklist", BlacklistLive

    resources "/password_resets", PasswordResetController, only: [:update, :new, :create]
    get "/password_resets/:reset_token", PasswordResetController, :edit

    resources "/user", UserController, singleton: true, only: [:show, :edit, :update, :delete]
    resources "/users", UserController, only: [:new, :create]

    resources "/devices", DeviceController, except: [:new, :update, :edit]

    resources "/session", SessionController, singleton: true, only: [:delete]
    resources "/sessions", SessionController, only: [:new, :create]

    get "/", SessionController, :new
  end
end
