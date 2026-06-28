defmodule PortalAPI.ApiSpec do
  alias OpenApiSpex.{Components, Info, OpenApi, Paths, SecurityScheme, Server}
  alias PortalAPI.{Endpoint, Router}
  @behaviour OpenApi

  @impl OpenApi
  def spec do
    %OpenApi{
      servers: [server()],
      info: %Info{
        title: "Firezone API",
        version: "1.0",
        description: """
        The Firezone REST API is eventually consistent. After creating or updating \
        a resource, it may take a second or two for the change to be reflected in \
        subsequent read requests. If you receive a 404 for a recently created or \
        updated entity, wait briefly and retry the request.\
        """
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
  end

  defp server do
    case Portal.Config.get_env(:portal, :rest_api_url) do
      nil -> Server.from_endpoint(Endpoint)
      url -> %Server{url: String.trim_trailing(url, "/")}
    end
  end
end
