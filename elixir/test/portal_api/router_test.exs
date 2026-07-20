defmodule PortalAPI.RouterTest do
  use ExUnit.Case, async: true

  # The `/v1` scope and the legacy unversioned scope are hand-duplicated in
  # router.ex (a shared macro doesn't resolve inside Phoenix's `scope` DSL).
  # This guards against them drifting apart silently - see the comment above
  # both scopes in router.ex.
  @non_dual_scope_prefixes ["/v1", "/openapi", "/swaggerui", "/ingestion", "/integrations"]

  test "the /v1 scope and the legacy scope expose the same route set" do
    routes = Phoenix.Router.routes(PortalAPI.Router)

    v1_routes =
      for %{verb: verb, path: "/v1" <> path} <- routes, into: MapSet.new() do
        {verb, path}
      end

    legacy_routes =
      for %{verb: verb, path: path} <- routes,
          not String.starts_with?(path, @non_dual_scope_prefixes),
          into: MapSet.new() do
        {verb, path}
      end

    assert MapSet.equal?(v1_routes, legacy_routes), """
    /v1 and legacy route sets have drifted apart.

    Only in /v1: #{inspect(MapSet.difference(v1_routes, legacy_routes))}
    Only in legacy: #{inspect(MapSet.difference(legacy_routes, v1_routes))}
    """
  end
end
