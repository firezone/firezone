defmodule Web.Router do
  use Web, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :protect_from_forgery
    plug :fetch_live_flash
    plug :put_root_layout, {Web.Layouts, :root}
  end

  pipeline :api do
    plug :accepts, ["json"]
    # TODO: auth
  end

  pipeline :public do
    plug :accepts, ["html", "xml"]
  end

  live_session :admin do
    scope "/", Web do
      pipe_through :browser

      live "/", DashboardLive

      # Users
      live "/users", UsersLive.Index
      live "/users/new", UsersLive.New
      live "/users/:id/edit", UsersLive.Edit
      live "/users/:id", UsersLive.Show

      # Groups
      live "/groups", GroupsLive.Index
      live "/groups/new", GroupsLive.New
      live "/groups/:id/edit", GroupsLive.Edit
      live "/groups/:id", GroupsLive.Show

      # Devices
      live "/devices", DevicesLive.Index
      live "/devices/:id", DevicesLive.Show

      # Gateways
      live "/gateways", GatewaysLive.Index
      live "/gateways/new", GatewaysLive.New
      live "/gateways/:id/edit", GatewaysLive.Edit
      live "/gateways/:id", GatewaysLive.Show

      # Resources
      live "/resources", ResourcesLive.Index
      live "/resources/new", ResourcesLive.New
      live "/resources/:id/edit", ResourcesLive.Edit
      live "/resources/:id", ResourcesLive.Show

      # Policies
      live "/policies", PoliciesLive.Index
      live "/policies/new", PoliciesLive.New
      live "/policies/:id/edit", PoliciesLive.Edit
      live "/policies/:id", PoliciesLive.Show

      # Settings
      live "/settings/account", SettingsLive.Account
      live "/settings/identity_providers", SettingsLive.IdentityProviders.Index
      live "/settings/identity_providers/new", SettingsLive.NewIdentityProviders.New
      live "/settings/identity_providers/:id", SettingsLive.NewIdentityProviders.Show
      live "/settings/identity_providers/:id/edit", SettingsLive.NewIdentityProviders.Edit
      live "/settings/dns", SettingsLive.Dns
      live "/settings/api_tokens", SettingsLive.ApiTokens.Index
      live "/settings/api_tokens/new", SettingsLive.ApiTokens.New
    end
  end

  scope "/browser", Web do
    pipe_through :public

    get "/config.xml", BrowserController, :config
  end

  get "/healthz", Web.HealthController, :healthz
end
