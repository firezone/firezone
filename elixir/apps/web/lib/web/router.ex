defmodule Web.Router do
  use Web, :router
  import Web.Auth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :protect_from_forgery
    plug :fetch_live_flash
    plug :put_root_layout, {Web.Layouts, :root}
    plug :fetch_user_agent
    plug :fetch_subject
  end

  pipeline :api do
    plug :accepts, ["json"]
    plug :ensure_authenticated
    plug :ensure_authenticated_actor_type, :service_account
  end

  pipeline :public do
    plug :accepts, ["html", "xml"]
  end

  pipeline :ensure_authenticated_admin do
    plug :ensure_authenticated
    plug :ensure_authenticated_actor_type, :account_admin_user
  end

  scope "/browser", Web do
    pipe_through :public

    get "/config.xml", BrowserController, :config
  end

  scope "/", Web do
    pipe_through :public

    get "/healthz", HealthController, :healthz
  end

  if Mix.env() in [:dev, :test] do
    scope "/dev" do
      pipe_through [:public]
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end

  scope "/:account_id/sign_in", Web do
    pipe_through [:browser, :redirect_if_user_is_authenticated]

    live_session :redirect_if_user_is_authenticated,
      on_mount: [
        Web.Sandbox,
        {Web.Auth, :redirect_if_user_is_authenticated}
      ] do
      live "/", Auth.ProvidersLive, :new

      # Adapter-specific routes
      ## Email
      live "/providers/email/:provider_id", Auth.EmailLive, :confirm
    end

    scope "/providers/:provider_id" do
      # UserPass
      post "/verify_credentials", AuthController, :verify_credentials

      # Email
      post "/request_magic_link", AuthController, :request_magic_link
      get "/verify_sign_in_token", AuthController, :verify_sign_in_token

      # IdP
      get "/redirect", AuthController, :redirect_to_idp
      get "/handle_callback", AuthController, :handle_idp_callback
    end
  end

  scope "/:account_id/scim/v2", Web do
    pipe_through [:api]

    get "/", ScimController, :index
    # TODO: SCIM endpoints
  end

  scope "/:account_id", Web do
    pipe_through [:browser]

    get "/sign_out", AuthController, :sign_out

    live_session :landing,
      on_mount: [Web.Sandbox] do
      live "/", LandingLive
    end
  end

  scope "/:account_id", Web do
    pipe_through [:browser, :ensure_authenticated_admin]

    live_session :ensure_authenticated,
      on_mount: [
        Web.Sandbox,
        {Web.Auth, :ensure_authenticated},
        {Web.Auth, :ensure_account_admin_user_actor},
        {Web.Auth, :mount_account}
      ] do
      live "/dashboard", DashboardLive

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
      live "/settings/identity_providers/new", SettingsLive.IdentityProviders.New

      # TODO: /settings/identity_providers/new/:adapter
      live "/settings/identity_providers/new/openid_connect",
           SettingsLive.IdentityProviders.New.OpenIDConnect

      live "/settings/identity_providers/new/saml", SettingsLive.IdentityProviders.New.SAML
      live "/settings/identity_providers/:provider_id", SettingsLive.IdentityProviders.Show
      live "/settings/identity_providers/:provider_id/edit", SettingsLive.IdentityProviders.Edit
      live "/settings/dns", SettingsLive.Dns
      live "/settings/api_tokens", SettingsLive.ApiTokens.Index
      live "/settings/api_tokens/new", SettingsLive.ApiTokens.New
    end
  end
end
