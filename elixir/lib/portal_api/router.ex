defmodule PortalAPI.Router do
  use PortalAPI, :router

  pipeline :api do
    plug :accepts, ["json"]
    # Authentication and the account limiter use only request metadata. Keep
    # them ahead of the body parser so rejected requests never buffer or decode
    # an attacker-controlled JSON body.
    plug PortalAPI.Plugs.Auth
    plug PortalAPI.Plugs.RateLimit

    plug PortalAPI.Plugs.ParseBody,
      parsers: [:json],
      pass: ["*/*"],
      json_decoder: Phoenix.json_library()

    plug PortalAPI.Plugs.RequestLog
    plug PortalAPI.Plugs.Scope
    plug PortalAPI.Plugs.ValidateUUIDParams
    plug OpenApiSpex.Plug.PutApiSpec, module: PortalAPI.ApiSpec
  end

  pipeline :public do
    plug :accepts, ["html", "xml", "json"]
    plug OpenApiSpex.Plug.PutApiSpec, module: PortalAPI.ApiSpec
  end

  scope "/openapi" do
    pipe_through :public

    get "/", PortalAPI.OpenAPIController, :index
  end

  scope "/openapi.json" do
    pipe_through :public

    get "/", OpenApiSpex.Plug.RenderSpec, []
  end

  scope "/swaggerui" do
    pipe_through :public

    get "/", OpenApiSpex.Plug.SwaggerUI, path: "/openapi.json"
  end

  pipeline :ingestion do
    plug :accepts, ["json"]
    # Rate limiting is keyed on the source IP and runs before token
    # verification and parsing. The ingest token is entirely in the
    # Authorization header, so it can also be authenticated before reading the
    # body.
    plug PortalAPI.Plugs.IngestionRateLimit
    plug PortalAPI.Plugs.FlowLogAuth

    plug Plug.Parsers,
      parsers: [:json],
      pass: ["*/*"],
      json_decoder: Phoenix.json_library(),
      length: 10_000_000
  end

  scope "/ingestion", PortalAPI do
    pipe_through :ingestion

    post "/flow_logs", FlowLogController, :create
  end

  # URL versioning was tried (a /v1 prefix scope duplicating every route
  # below) and rolled back before ever shipping as the documented surface -
  # see git history if reviving it. Versioning strategy is deliberately
  # undecided until an actual breaking change forces the question.
  scope "/", PortalAPI do
    pipe_through :api

    resources "/account", AccountController, only: [:show], singleton: true

    resources "/clients", ClientController, except: [:new, :edit, :create]
    put "/clients/:id/verify", ClientController, :verify
    put "/clients/:id/unverify", ClientController, :unverify

    get "/logs", LogController, :index
    get "/logs/:log_id", LogController, :show

    resources "/resources", ResourceController, except: [:new, :edit] do
      get "/pool_members", PoolMemberController, :index
      put "/pool_members", PoolMemberController, :update_put
      patch "/pool_members", PoolMemberController, :update_patch
    end
    resources "/policies", PolicyController, except: [:new, :edit]

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
    get "/x509_auth_provider", X509AuthProviderController, :show
    resources "/oidc_auth_providers", OIDCAuthProviderController, only: [:index, :show]
    resources "/google_auth_providers", GoogleAuthProviderController, only: [:index, :show]
    resources "/entra_auth_providers", EntraAuthProviderController, only: [:index, :show]
    resources "/okta_auth_providers", OktaAuthProviderController, only: [:index, :show]
    resources "/google_directories", GoogleDirectoryController, only: [:index, :show]
    resources "/entra_directories", EntraDirectoryController, only: [:index, :show]
    resources "/okta_directories", OktaDirectoryController, only: [:index, :show]
    resources "/intune_posture_providers", IntunePostureProviderController,
      only: [:index, :show]

    resources "/intune_devices", IntuneDeviceController, only: [:index, :show]

    resources "/iru_posture_providers", IruPostureProviderController,
      only: [:index, :show]

    resources "/iru_devices", IruDeviceController, only: [:index, :show]

    resources "/defender_posture_providers", DefenderPostureProviderController,
      only: [:index, :show]

    resources "/defender_devices", DefenderDeviceController, only: [:index, :show]

    resources "/santa_posture_providers", SantaPostureProviderController,
      only: [:index, :show]

    resources "/santa_devices", SantaDeviceController, only: [:index, :show]

    resources "/sentinelone_posture_providers", SentinelOnePostureProviderController,
      only: [:index, :show]

    resources "/sentinelone_devices", SentinelOneDeviceController, only: [:index]
    get "/sentinelone_devices/:sentinelone_agent", SentinelOneDeviceController, :show
  end

  scope "/integrations", PortalAPI.Integrations do
    scope "/azure_communication_services", AzureCommunicationServices do
      post "/webhooks", WebhookController, :handle_webhook
    end

    scope "/entra", Entra do
      post "/webhooks", WebhookController, :handle_webhook
    end

    scope "/google", Google do
      post "/webhooks", WebhookController, :handle_webhook
    end

    scope "/stripe", Stripe do
      post "/webhooks", WebhookController, :handle_webhook
    end
  end
end
