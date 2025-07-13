defmodule API.Router do
  use API, :router

  pipeline :api do
    plug Plug.Parsers,
      parsers: [:json],
      pass: ["*/*"],
      json_decoder: Phoenix.json_library()

    plug :accepts, ["json"]
    plug API.Plugs.Auth
    plug API.Plugs.RateLimit
  end

  pipeline :public do
    plug :accepts, ["html", "xml", "json"]
  end

  pipeline :openapi do
    plug OpenApiSpex.Plug.PutApiSpec, module: API.ApiSpec
  end

  scope "/openapi" do
    pipe_through :openapi

    get "/", OpenApiSpex.Plug.RenderSpec, []
  end

  scope "/swaggerui" do
    pipe_through :public

    get "/", OpenApiSpex.Plug.SwaggerUI, path: "/openapi"
  end

  scope "/", API do
    pipe_through :public

    get "/healthz", HealthController, :healthz
  end

  scope "/", API do
    pipe_through :api

    resources "/clients", ClientController, except: [:new, :edit, :create] do
      get "/flows", FlowController, :index_for_client
    end

    put "/clients/:id/verify", ClientController, :verify
    put "/clients/:id/unverify", ClientController, :unverify

    resources "/resources", ResourceController, except: [:new, :edit] do
      get "/flows", FlowController, :index_for_resource
    end

    resources "/policies", PolicyController, except: [:new, :edit] do
      get "/flows", FlowController, :index_for_policy
    end

    resources "/flows", FlowController, only: [:index, :show]

    resources "/gateway_groups", GatewayGroupController, except: [:new, :edit] do
      post "/tokens", GatewayGroupController, :create_token
      delete "/tokens", GatewayGroupController, :delete_all_tokens
      delete "/tokens/:id", GatewayGroupController, :delete_token

      resources "/gateways", GatewayController, except: [:new, :edit, :create, :update] do
        get "/flows", FlowController, :index_for_gateway
      end
    end

    resources "/actors", ActorController, except: [:new, :edit] do
      resources "/identities", IdentityController, except: [:new, :edit, :create, :update]
      post "/providers/:provider_id/identities/", IdentityController, :create
      get "/flows", FlowController, :index_for_actor
    end

    resources "/actor_groups", ActorGroupController, except: [:new, :edit] do
      get "/memberships", ActorGroupMembershipController, :index
      put "/memberships", ActorGroupMembershipController, :update_put
      patch "/memberships", ActorGroupMembershipController, :update_patch
    end

    resources "/identity_providers", IdentityProviderController, only: [:index, :show, :delete]
  end

  scope "/integrations", API.Integrations do
    scope "/stripe", Stripe do
      post "/webhooks", WebhookController, :handle_webhook
    end
  end
end
