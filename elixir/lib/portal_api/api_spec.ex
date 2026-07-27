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

  @excluded_prefixes ["/openapi", "/swaggerui", "/ingestion", "/integrations"]

  defp api_paths do
    Router
    |> Paths.from_router()
    |> Enum.reject(fn {path, _item} -> String.starts_with?(path, @excluded_prefixes) end)
    |> Map.new()
  end

  # Private operations are resolved first so their schemas remain available as
  # contracts without advertising the operations as customer-facing API routes.
  #
  # @excluded_prefixes above already drops all of /ingestion, so this is
  # currently a no-op. It stays because the two serve different purposes:
  # the prefix list excludes whole non-API scopes, while this drops
  # individual operations whose schemas still need resolving. Narrowing
  # the prefix list would make this load-bearing again.
  defp remove_private_paths(spec) do
    %{spec | paths: Map.drop(spec.paths, @private_paths)}
  end
end
