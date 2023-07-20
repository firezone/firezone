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

      scope "/actors", UsersLive do
        live "/", Index
        live "/new", New
        live "/:id/edit", Edit
        live "/:id", Show
      end

      scope "/groups", GroupsLive do
        live "/", Index
        live "/new", New
        live "/:id/edit", Edit
        live "/:id", Show
      end

      scope "/devices", DevicesLive do
        live "/", Index
        live "/:id", Show
      end

      scope "/gateways", GatewaysLive do
        live "/", Index
        live "/new", New
        live "/:id/edit", Edit
        live "/:id", Show
      end

      scope "/resources", ResourcesLive do
        live "/", Index
        live "/new", New
        live "/:id/edit", Edit
        live "/:id", Show
      end

      scope "/policies", PoliciesLive do
        live "/", Index
        live "/new", New
        live "/:id/edit", Edit
        live "/:id", Show
      end

      scope "/settings", SettingsLive do
        live "/account", Account

        scope "/identity_providers", IdentityProviders do
          live "/", Index
          live "/:provider_id", Show
          live "/:provider_id/edit", Edit

          live "/new", New
          live "/new/openid_connect", New.OpenIDConnect
          live "/new/saml", New.SAML
        end

        live "/dns", DNS

        scope "/api_tokens", APITokens do
          live "/", Index
          live "/new", New
        end
      end
    end
  end

  scope "/", Web do
    pipe_through [:browser]

    live_session :landing,
      on_mount: [Web.Sandbox] do
      live "/:account_id/", LandingLive
      live "/", LandingLive
    end
  end
end
