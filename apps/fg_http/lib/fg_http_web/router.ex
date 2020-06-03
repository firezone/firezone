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
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", FgHttpWeb do
    pipe_through :browser

    resources "/password_resets", PasswordResetController, only: [:update, :new, :create]
    get "/password_resets/:reset_token", PasswordResetController, :edit

    resources "/user", UserController, singleton: true, only: [:show, :edit, :update, :delete]
    resources "/users", UserController, only: [:new, :create]

    resources "/devices", DeviceController do
      resources "/rules", RuleController, only: [:new, :index, :create]
    end

    resources "/rules", RuleController, only: [:show, :update, :delete, :edit]

    resources "/sessions", SessionController, only: [:new, :create, :delete]

    get "/", SessionController, :new
  end

  # Other scopes may use custom stacks.
  # scope "/api", FgHttpWeb do
  #   pipe_through :api
  # end
end
