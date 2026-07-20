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
      # Populate the paths from a phoenix router. The router also serves an
      # unversioned copy of every route as a deprecated compatibility shim
      # (see router.ex) - that surface isn't documented going forward, so
      # only the /v1 paths are included here, with the /v1 prefix stripped
      # (the server URL below carries it instead).
      paths: v1_paths(),
      components: %Components{
        securitySchemes: %{"authorization" => %SecurityScheme{type: "http", scheme: "bearer"}}
      },
      security: [%{"authorization" => []}]
    }
    # Discover request/response schemas from path specs
    |> OpenApiSpex.resolve_schema_modules()
    |> remove_private_paths()
  end

  defp v1_paths do
    Router
    |> Paths.from_router()
    |> Enum.filter(fn {path, _item} -> String.starts_with?(path, "/v1/") end)
    |> Map.new(fn {path, item} -> {String.trim_leading(path, "/v1"), item} end)
  end

  # Private operations are resolved first so their schemas remain available as
  # contracts without advertising the operations as customer-facing API routes.
  defp remove_private_paths(spec) do
    %{spec | paths: Map.drop(spec.paths, @private_paths)}
  end
end
