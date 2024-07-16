defmodule API.Router do
  use API, :router

  pipeline :api do
    plug Plug.Parsers,
      parsers: [:json],
      pass: ["*/*"],
      json_decoder: Phoenix.json_library()

    plug :accepts, ["json"]
    plug API.Plugs.Auth
  end

  pipeline :public do
    plug :accepts, ["html", "xml", "json"]
  end

  scope "/", API do
    pipe_through :public

    get "/healthz", HealthController, :healthz
  end

  scope "/v1", API do
    pipe_through :api

    resources "/resources", ResourceController, except: [:new, :edit]
    resources "/policies", PolicyController, except: [:new, :edit]

    resources "/gateway_groups", GatewayGroupController, except: [:new, :edit] do
      post "/tokens", GatewayGroupController, :create_token
      delete "/tokens", GatewayGroupController, :delete_all_tokens
      delete "/tokens/:id", GatewayGroupController, :delete_token
      resources "/gateways", GatewayController, except: [:new, :edit, :create, :update]
    end

    resources "/actors", ActorController, except: [:new, :edit] do
      resources "/identities", IdentityController, except: [:new, :edit, :update]
      post "/providers/:provider_id/identities/", IdentityController, :create
    end

    resources "/actor_groups", ActorGroupController, except: [:new, :edit] do
      get "/memberships", ActorGroupMembershipController, :index
      put "/memberships", ActorGroupMembershipController, :update
      patch "/memberships", ActorGroupMembershipController, :update
    end

    resources "/identity_providers", IdentityProviderController, only: [:index, :show, :delete]
  end

  scope "/integrations", API.Integrations do
    scope "/stripe", Stripe do
      post "/webhooks", WebhookController, :handle_webhook
    end
  end
end
