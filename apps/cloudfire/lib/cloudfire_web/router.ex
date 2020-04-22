defmodule CloudfireWeb.Router do
  use CloudfireWeb, :router

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

  scope "/", CloudfireWeb do
    pipe_through :browser

    get "/", PageController, :index

    resources "/user", UserController, singleton: true, only: [:show, :edit, :update, :delete]
    resources "/users", UserController, only: [:new, :create]
    resources "/devices", DeviceController, except: [:create] do
      resources "/firewall_rules", FirewallRuleController, only: [:new, :index, :create]
    end
    resources "/firewall_rules", FirewallRuleController, only: [:show, :update, :delete, :edit]
  end

  # Other scopes may use custom stacks.
  # scope "/api", CloudfireWeb do
  #   pipe_through :api
  # end
end
