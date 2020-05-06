defmodule CfHttpWeb.Router do
  use CfHttpWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_flash
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", CfHttpWeb do
    pipe_through :browser

    get "/", PageController, :index

    resources "/user", UserController, singleton: true, only: [:show, :edit, :update, :delete]
    resources "/users", UserController, only: [:new, :create]

    resources "/devices", DeviceController, except: [:create] do
      resources "/rules", RuleController, only: [:new, :index, :create]
    end

    resources "/rules", RuleController, only: [:show, :update, :delete, :edit]
  end

  # Other scopes may use custom stacks.
  # scope "/api", CfHttpWeb do
  #   pipe_through :api
  # end
end
