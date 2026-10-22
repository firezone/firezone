# Vendored from https://github.com/firezone/openid_connect, a fork of
# https://github.com/DockYard/openid_connect by DockYard, Inc.
# MIT licensed; see lib/openid_connect/LICENSE.md.
defmodule OpenIDConnect.Fixtures do
  @moduledoc """
  Test fixtures for OpenIDConnect using Req.Test.
  """

  def start_fixture(provider, overrides \\ %{}) do
    test_name = unique_test_name()
    endpoint = "http://#{test_name}/"
    {jwks, overrides} = Map.pop(overrides, "jwks")

    Req.Test.stub(test_name, fn conn ->
      handle_fixture_request(conn, provider, endpoint, jwks, overrides)
    end)

    {test_name, "#{endpoint}.well-known/discovery-document.json"}
  end

  defp handle_fixture_request(conn, provider, endpoint, jwks, overrides) do
    case conn.request_path do
      "/.well-known/jwks.json" ->
        serve_jwks(conn, provider, jwks)

      "/.well-known/discovery-document.json" ->
        serve_discovery_document(conn, provider, endpoint, overrides)

      _ ->
        serve_not_found(conn)
    end
  end

  @doc """
  Creates a fixture with custom route handlers.

  The `custom_routes` parameter is a map of {method, path} => handler_fn.
  Handler functions receive conn and should return conn.

  Custom routes automatically update the discovery document endpoints:
  - {"POST", "/token"} sets token_endpoint
  - {"GET", "/userinfo"} sets userinfo_endpoint
  """
  def start_fixture_with_routes(provider, overrides \\ %{}, custom_routes \\ %{}) do
    test_name = unique_test_name()
    endpoint = "http://#{test_name}/"
    {jwks, overrides} = Map.pop(overrides, "jwks")
    auto_endpoints = build_auto_endpoints(custom_routes, endpoint)

    Req.Test.stub(test_name, fn conn ->
      handle_routed_request(
        conn,
        provider,
        endpoint,
        jwks,
        overrides,
        custom_routes,
        auto_endpoints
      )
    end)

    {test_name, "#{endpoint}.well-known/discovery-document.json"}
  end

  defp build_auto_endpoints(custom_routes, endpoint) do
    %{}
    |> maybe_put_endpoint(custom_routes, {"POST", "/token"}, "token_endpoint", "#{endpoint}token")
    |> maybe_put_endpoint(
      custom_routes,
      {"GET", "/userinfo"},
      "userinfo_endpoint",
      "#{endpoint}userinfo"
    )
  end

  defp maybe_put_endpoint(map, custom_routes, route_key, endpoint_key, endpoint_value) do
    if Map.has_key?(custom_routes, route_key) do
      Map.put(map, endpoint_key, endpoint_value)
    else
      map
    end
  end

  defp handle_routed_request(
         conn,
         provider,
         endpoint,
         jwks,
         overrides,
         custom_routes,
         auto_endpoints
       ) do
    route_key = {conn.method, conn.request_path}
    wildcard_key = {"*", conn.request_path}

    cond do
      handler = Map.get(custom_routes, route_key) ->
        handler.(conn)

      handler = Map.get(custom_routes, wildcard_key) ->
        handler.(conn)

      conn.request_path == "/.well-known/jwks.json" ->
        serve_jwks(conn, provider, jwks)

      conn.request_path == "/.well-known/discovery-document.json" ->
        serve_discovery_document_with_auto_endpoints(
          conn,
          provider,
          endpoint,
          overrides,
          auto_endpoints
        )

      true ->
        serve_not_found(conn)
    end
  end

  defp serve_jwks(conn, provider, jwks_override) do
    {status_code, body, headers} = load_fixture(provider, "jwks")
    body = jwks_override || body
    send_response(conn, status_code, body, headers)
  end

  defp serve_discovery_document(conn, provider, endpoint, overrides) do
    {status_code, body, headers} = load_fixture(provider, "discovery_document")

    body =
      body
      |> Map.put("jwks_uri", "#{endpoint}.well-known/jwks.json")
      |> Map.merge(overrides)

    send_response(conn, status_code, body, headers)
  end

  defp serve_discovery_document_with_auto_endpoints(
         conn,
         provider,
         endpoint,
         overrides,
         auto_endpoints
       ) do
    {status_code, body, headers} = load_fixture(provider, "discovery_document")

    body =
      body
      |> Map.put("jwks_uri", "#{endpoint}.well-known/jwks.json")
      |> Map.merge(overrides)
      |> Map.merge(auto_endpoints)

    send_response(conn, status_code, body, headers)
  end

  defp serve_not_found(conn) do
    conn
    |> Plug.Conn.put_status(404)
    |> Req.Test.json(%{error: "not_found"})
  end

  def load_fixture(provider, type) do
    {%{status_code: status_code, body: body, headers: headers}, _} =
      Code.eval_file("test/fixtures/http/#{provider}/#{type}.exs")

    {status_code, body, headers}
  end

  def send_response(conn, status_code, body, headers) do
    conn =
      Enum.reduce(headers, conn, fn {key, value}, conn ->
        Plug.Conn.put_resp_header(conn, String.downcase(key), value)
      end)

    conn
    |> Plug.Conn.put_status(status_code)
    |> Req.Test.json(body)
  end

  def req_test_options(test_name) do
    [plug: {Req.Test, test_name}]
  end

  def unique_test_name do
    :"test_#{System.unique_integer([:positive, :monotonic])}"
  end
end
