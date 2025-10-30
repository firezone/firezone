defmodule API.ApiSpec do
  alias OpenApiSpex.{
    Components,
    Info,
    OpenApi,
    Paths,
    SecurityScheme,
    Server,
    Response,
    MediaType
  }

  alias API.{Endpoint, Router}
  @behaviour OpenApi

  @impl OpenApi
  def spec do
    %OpenApi{
      servers: [
        # Populate the Server info from a phoenix endpoint
        Server.from_endpoint(Endpoint)
      ],
      info: %Info{
        title: "Firezone API",
        version: "1.0"
      },
      # Populate the paths from a phoenix router
      paths: Paths.from_router(Router),
      components: %Components{
        securitySchemes: %{"authorization" => %SecurityScheme{type: "http", scheme: "bearer"}},
        responses: %{
          JSONError: %Response{
            description: "JSON Error",
            content: %{
              "application/json" => %MediaType{schema: API.Schemas.JSONError.schema()}
            }
          }
        }
      },
      security: [%{"authorization" => []}]
    }
    # Discover request/response schemas from path specs
    |> OpenApiSpex.resolve_schema_modules()
  end
end
