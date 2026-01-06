defmodule PortalAPI.Router do
  use PortalAPI, :router

  pipeline :api do
    plug Plug.Parsers,
      parsers: [:json],
      pass: ["*/*"],
      json_decoder: Phoenix.json_library()

    plug :accepts, ["json"]
    plug PortalAPI.Plugs.Auth
    plug PortalAPI.Plugs.RateLimit
  end

  pipeline :public do
    plug :accepts, ["html", "xml", "json"]
  end

  pipeline :openapi do
    plug OpenApiSpex.Plug.PutApiSpec, module: PortalAPI.ApiSpec
  end

  scope "/openapi" do
    pipe_through :openapi

    get "/", OpenApiSpex.Plug.RenderSpec, []
  end

  scope "/swaggerui" do
    pipe_through :public

    get "/", OpenApiSpex.Plug.SwaggerUI, path: "/openapi"
  end

  scope "/", PortalAPI do
    pipe_through :api

    resources "/account", AccountController, only: [:show], singleton: true

    resources "/clients", ClientController, except: [:new, :edit, :create]
    put "/clients/:id/verify", ClientController, :verify
    put "/clients/:id/unverify", ClientController, :unverify

    resources "/resources", ResourceController, except: [:new, :edit]
    resources "/policies", PolicyController, except: [:new, :edit]

    resources "/sites", SiteController, except: [:new, :edit] do
      post "/gateway_tokens", GatewayTokenController, :create
      delete "/gateway_tokens", GatewayTokenController, :delete_all
      delete "/gateway_tokens/:id", GatewayTokenController, :delete
      resources "/gateways", GatewayController, except: [:new, :edit, :create, :update]
    end

    resources "/actors", ActorController, except: [:new, :edit] do
      resources "/external_identities", ExternalIdentityController, only: [:index, :show, :delete]
    end

    resources "/groups", GroupController, except: [:new, :edit] do
      get "/memberships", MembershipController, :index
      put "/memberships", MembershipController, :update_put
      patch "/memberships", MembershipController, :update_patch
    end

    resources "/userpass_auth_providers", UserpassAuthProviderController, only: [:index, :show]
    resources "/email_otp_auth_providers", EmailOTPAuthProviderController, only: [:index, :show]
    resources "/oidc_auth_providers", OIDCAuthProviderController, only: [:index, :show]
    resources "/google_auth_providers", GoogleAuthProviderController, only: [:index, :show]
    resources "/entra_auth_providers", EntraAuthProviderController, only: [:index, :show]
    resources "/okta_auth_providers", OktaAuthProviderController, only: [:index, :show]
    resources "/google_directories", GoogleDirectoryController, only: [:index, :show]
    resources "/entra_directories", EntraDirectoryController, only: [:index, :show]
    resources "/okta_directories", OktaDirectoryController, only: [:index, :show]
  end

  scope "/integrations", PortalAPI.Integrations do
    scope "/stripe", Stripe do
      post "/webhooks", WebhookController, :handle_webhook
    end
  end
end
