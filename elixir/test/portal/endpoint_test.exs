defmodule Portal.EndpointTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias Portal.Endpoint

  setup do
    Portal.Config.put_env_override(:portal, :web_external_url, "https://app.firezone.test/")
    Portal.Config.put_env_override(:portal, :api_external_url, "https://api.firezone.test/")
    Portal.Config.put_env_override(:portal, :rest_api_url, "https://rest-api.firezone.test/")
    Portal.Config.put_env_override(:portal, :flow_logs_api_url, "https://flow-api.firezone.test/")
    Portal.Config.put_env_override(:portal, :mtls_external_url, "https://mtls.firezone.test/")
  end

  test "redirects public HTTP requests to HTTPS" do
    conn = Endpoint.call(conn(:get, "http://api.firezone.test/client?foo=bar"), [])

    assert conn.status == 301
    assert get_resp_header(conn, "location") == ["https://api.firezone.test/client?foo=bar"]
  end

  test "preserves the method when redirecting a non-GET request" do
    conn = Endpoint.call(conn(:post, "http://flow-api.firezone.test/ingestion/flow_logs"), [])

    assert conn.status == 307
    assert get_resp_header(conn, "location") == [
             "https://flow-api.firezone.test/ingestion/flow_logs"
           ]
  end

  test "serves readiness checks without redirecting" do
    conn = Endpoint.call(conn(:get, "http://api.firezone.test/readyz"), [])

    assert conn.status in [200, 503]
    assert get_resp_header(conn, "location") == []
  end

  test "dispatches the web hostname to the web endpoint" do
    conn = Endpoint.call(conn(:get, "https://app.firezone.test/not-found"), [])

    assert conn.private.phoenix_endpoint == PortalWeb.Endpoint
  end

  test "dispatches every API hostname to the API endpoint" do
    for host <- ~w(api.firezone.test rest-api.firezone.test flow-api.firezone.test) do
      conn = Endpoint.call(conn(:get, "https://#{host}/not-found"), [])
      assert conn.private.phoenix_endpoint == PortalAPI.Endpoint
    end
  end

  test "only exposes WebSocket requests on the mutual-TLS hostname" do
    rejected = Endpoint.call(conn(:get, "https://mtls.firezone.test/not-found"), [])
    assert rejected.status == 404
    assert rejected.private.phoenix_endpoint == Endpoint

    forwarded =
      :get
      |> conn("https://mtls.firezone.test/not-found")
      |> put_req_header("upgrade", "websocket")
      |> Endpoint.call([])

    assert forwarded.private.phoenix_endpoint == PortalAPI.Endpoint
  end

  test "rejects unknown hostnames" do
    conn = Endpoint.call(conn(:get, "https://unknown.firezone.test/"), [])

    assert conn.status == 404
    assert conn.private.phoenix_endpoint == Endpoint
  end
end
