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
    plug PortalAPI.Plugs.RequestLog
    plug PortalAPI.Plugs.ValidateUUIDParams
  end

  # Adds Deprecation/Sunset/Link headers (RFC 8594) to the legacy unversioned
  # API routes, which are superseded by /v1. See PortalAPI.Plugs.LegacyDeprecation.
  pipeline :deprecation_headers do
    plug PortalAPI.Plugs.LegacyDeprecation
  end

  pipeline :public do
    plug :accepts, ["html", "xml", "json"]
  end

  scope "/openapi" do
    pipe_through :public

    get "/", PortalAPI.OpenAPIController, :index
  end

  scope "/swaggerui" do
    pipe_through :public

    get "/", OpenApiSpex.Plug.SwaggerUI, path: "/openapi.json"
  end

  pipeline :ingestion do
    plug Plug.Parsers,
      parsers: [:json],
      pass: ["*/*"],
      json_decoder: Phoenix.json_library(),
      length: 10_000_000

    plug :accepts, ["json"]
    # Auth is the per-authorization ingest token in the Authorization header,
    # verified in the controller (it needs the token's account_id to load the
    # signing key). Rate limiting is keyed on the source IP.
    plug PortalAPI.Plugs.IngestionRateLimit
  end

  scope "/ingestion", PortalAPI do
    pipe_through :ingestion

    post "/flow_logs", FlowLogController, :create
  end

  # The REST API is versioned via a URL path prefix (/v1) rather than headers,
  # since it's primarily consumed by generated clients (e.g. a Terraform
  # provider) built from the OpenAPI spec, which map cleanly to one server URL
  # per contract version. /v1 is the current, documented, and only spec'd
  # surface (see PortalAPI.ApiSpec) - the bare, unversioned routes below exist
  # only as a deprecated compatibility shim for callers who haven't migrated
  # yet, and are served with Deprecation/Sunset headers until their sunset
  # date (config :portal, PortalAPI.Plugs.LegacyDeprecation, sunset_at: ...).
  #
  # Both scopes route directly to the same controllers (no redirect): a 3xx
  # redirect would cost every legacy client an extra round trip and is a
  # known footgun for Bearer-token HTTP clients, some of which don't resend
  # the Authorization header across a redirect by default.
  #
  # IMPORTANT: the route list below is intentionally duplicated verbatim
  # between the two scopes (a shared macro was tried and doesn't resolve
  # inside Phoenix's `scope` DSL) - keep them in sync when adding routes.
  # `mix phx.routes | grep v1` should show the same route count as the
  # unversioned scope, minus this comment's own drift risk.
  scope "/v1", PortalAPI do
    pipe_through :api

    resources "/account", AccountController, only: [:show], singleton: true

    resources "/clients", ClientController, except: [:new, :edit, :create]
    put "/clients/:id/verify", ClientController, :verify
    put "/clients/:id/unverify", ClientController, :unverify

    get "/logs", LogController, :index
    get "/logs/:log_id", LogController, :show

    resources "/resources", ResourceController, except: [:new, :edit]
    resources "/policies", PolicyController, except: [:new, :edit]
    post "/policies/:id/disable", PolicyController, :disable
    post "/policies/:id/enable", PolicyController, :enable

    resources "/sites", SiteController, except: [:new, :edit] do
      post "/gateway_tokens", GatewayTokenController, :create
      delete "/gateway_tokens", GatewayTokenController, :delete_all
      delete "/gateway_tokens/:id", GatewayTokenController, :delete
      resources "/gateways", GatewayController, except: [:new, :edit] do
        post "/token", GatewayTokenController, :create_for_gateway
        post "/token/rotate", GatewayTokenController, :rotate
      end
    end

    resources "/actors", ActorController, except: [:new, :edit] do
      post "/disable", ActorController, :disable
      post "/enable", ActorController, :enable
      resources "/external_identities", ExternalIdentityController, only: [:index, :show, :delete]
      get "/client_tokens", ClientTokenController, :index
      get "/client_tokens/:id", ClientTokenController, :show
      post "/client_tokens", ClientTokenController, :create
      delete "/client_tokens", ClientTokenController, :delete_all
      delete "/client_tokens/:id", ClientTokenController, :delete
    end

    resources "/groups", GroupController, except: [:new, :edit] do
      get "/memberships", MembershipController, :index
      put "/memberships", MembershipController, :update_put
      patch "/memberships", MembershipController, :update_patch
    end

    resources "/email_otp_auth_providers", EmailOTPAuthProviderController, only: [:index, :show]
    resources "/oidc_auth_providers", OIDCAuthProviderController, only: [:index, :show]
    resources "/google_auth_providers", GoogleAuthProviderController, only: [:index, :show]
    resources "/entra_auth_providers", EntraAuthProviderController, only: [:index, :show]
    resources "/okta_auth_providers", OktaAuthProviderController, only: [:index, :show]
    resources "/google_directories", GoogleDirectoryController, only: [:index, :show]
    resources "/entra_directories", EntraDirectoryController, only: [:index, :show]
    resources "/okta_directories", OktaDirectoryController, only: [:index, :show]
  end

  scope "/", PortalAPI do
    pipe_through [:api, :deprecation_headers]

    resources "/account", AccountController, only: [:show], singleton: true

    resources "/clients", ClientController, except: [:new, :edit, :create]
    put "/clients/:id/verify", ClientController, :verify
    put "/clients/:id/unverify", ClientController, :unverify

    get "/logs", LogController, :index
    get "/logs/:log_id", LogController, :show

    resources "/resources", ResourceController, except: [:new, :edit]
    resources "/policies", PolicyController, except: [:new, :edit]
    post "/policies/:id/disable", PolicyController, :disable
    post "/policies/:id/enable", PolicyController, :enable

    resources "/sites", SiteController, except: [:new, :edit] do
      post "/gateway_tokens", GatewayTokenController, :create
      delete "/gateway_tokens", GatewayTokenController, :delete_all
      delete "/gateway_tokens/:id", GatewayTokenController, :delete
      resources "/gateways", GatewayController, except: [:new, :edit] do
        post "/token", GatewayTokenController, :create_for_gateway
        post "/token/rotate", GatewayTokenController, :rotate
      end
    end

    resources "/actors", ActorController, except: [:new, :edit] do
      post "/disable", ActorController, :disable
      post "/enable", ActorController, :enable
      resources "/external_identities", ExternalIdentityController, only: [:index, :show, :delete]
      get "/client_tokens", ClientTokenController, :index
      get "/client_tokens/:id", ClientTokenController, :show
      post "/client_tokens", ClientTokenController, :create
      delete "/client_tokens", ClientTokenController, :delete_all
      delete "/client_tokens/:id", ClientTokenController, :delete
    end

    resources "/groups", GroupController, except: [:new, :edit] do
      get "/memberships", MembershipController, :index
      put "/memberships", MembershipController, :update_put
      patch "/memberships", MembershipController, :update_patch
    end

    resources "/email_otp_auth_providers", EmailOTPAuthProviderController, only: [:index, :show]
    resources "/oidc_auth_providers", OIDCAuthProviderController, only: [:index, :show]
    resources "/google_auth_providers", GoogleAuthProviderController, only: [:index, :show]
    resources "/entra_auth_providers", EntraAuthProviderController, only: [:index, :show]
    resources "/okta_auth_providers", OktaAuthProviderController, only: [:index, :show]
    resources "/google_directories", GoogleDirectoryController, only: [:index, :show]
    resources "/entra_directories", EntraDirectoryController, only: [:index, :show]
    resources "/okta_directories", OktaDirectoryController, only: [:index, :show]
    resources "/intune_integration", IntuneIntegrationController, only: [:show], singleton: true
    resources "/intune_devices", IntuneDeviceController, only: [:index, :show]
  end

  scope "/integrations", PortalAPI.Integrations do
    scope "/azure_communication_services", AzureCommunicationServices do
      post "/webhooks", WebhookController, :handle_webhook
    end

    scope "/stripe", Stripe do
      post "/webhooks", WebhookController, :handle_webhook
    end
  end
end
