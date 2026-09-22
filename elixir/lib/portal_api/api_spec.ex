defmodule PortalAPI.ApiSpec do
  alias OpenApiSpex.{Components, Info, OpenApi, Paths, SecurityScheme, Server}
  alias PortalAPI.Router
  @behaviour OpenApi

  @private_paths ["/ingestion/flow_logs"]

  @impl OpenApi
  def spec do
    %OpenApi{
      servers: [%Server{url: "/"}],
      info: %Info{
        title: "Firezone API",
        version: "1.0.0",
        description: """
        A REST API for configuring your Firezone account.
        """
      },
      # Populate the paths from a phoenix router, excluding the non-API
      # scopes (ingestion, third-party integration webhooks, and the
      # spec/UI routes themselves) - see router.ex.
      paths: api_paths(),
      components: %Components{
        securitySchemes: %{"authorization" => %SecurityScheme{type: "http", scheme: "bearer"}}
      },
      security: [%{"authorization" => []}]
    }
    # Discover request/response schemas from path specs
    |> OpenApiSpex.resolve_schema_modules()
    |> remove_private_paths()
  end

  # Deliberately excludes /ingestion, which remove_private_paths/1 handles
  # instead. Dropping it here would happen before resolve_schema_modules/1
  # runs, so the flow-log ingest schemas would never be discovered - and
  # they have to stay published as contracts even though the operation
  # isn't advertised.
  # /mcp is the Model Context Protocol endpoint. It speaks JSON-RPC rather than
  # REST and derives its tools from this very spec, so publishing it as an API
  # operation would be circular.
  @excluded_prefixes ["/openapi", "/swaggerui", "/integrations", "/mcp"]

  defp api_paths do
    Router
    |> Paths.from_router()
    |> Enum.reject(fn {path, _item} -> String.starts_with?(path, @excluded_prefixes) end)
    |> Map.new()
  end

  # Private operations are resolved first so their schemas remain available as
  # contracts without advertising the operations as customer-facing API routes.
  # That ordering is the whole point: excluding these paths in api_paths/0
  # instead would run before resolve_schema_modules/1 and lose the schemas.
  defp remove_private_paths(spec) do
    %{spec | paths: Map.drop(spec.paths, @private_paths)}
  end
end
