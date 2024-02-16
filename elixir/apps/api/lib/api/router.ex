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

    post "/echo", ExampleController, :echo
  end

  scope "/integrations", API.Integrations do
    scope "/stripe", Stripe do
      post "/webhooks", WebhookController, :handle_webhook
    end
  end
end
