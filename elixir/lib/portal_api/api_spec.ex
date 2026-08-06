defmodule PortalAPI.ApiSpec do
  alias OpenApiSpex.{Components, Info, OpenApi, Paths, SecurityScheme, Server}
  alias PortalAPI.{Endpoint, Router}
  @behaviour OpenApi

  @private_paths ["/ingestion/flow_logs"]

  @impl OpenApi
  def spec do
    %OpenApi{
      servers: [server()],
      info: %Info{
        title: "Firezone API",
        version: "1.0"
      },
      # Populate the paths from a phoenix router
      paths: Paths.from_router(Router),
      components: %Components{
        securitySchemes: %{"authorization" => %SecurityScheme{type: "http", scheme: "bearer"}}
      },
      security: [%{"authorization" => []}]
    }
    # Discover request/response schemas from path specs
    |> OpenApiSpex.resolve_schema_modules()
    |> remove_private_paths()
  end

  # Private operations are resolved first so their schemas remain available as
  # contracts without advertising the operations as customer-facing API routes.
  defp remove_private_paths(spec) do
    %{spec | paths: Map.drop(spec.paths, @private_paths)}
  end

  defp server do
    case Portal.Config.get_env(:portal, :rest_api_url) do
      nil -> Server.from_endpoint(Endpoint)
      url -> %Server{url: String.trim_trailing(url, "/")}
    end
  end
end
