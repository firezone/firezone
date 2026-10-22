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

  describe "when this endpoint terminates TLS" do
    setup do
      Portal.Config.put_env_override(:portal, Endpoint, https: [port: 443])
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

    test "does not trust forwarded headers from the public listener" do
      conn =
        :get
        |> conn("http://api.firezone.test/client")
        |> put_req_header("x-forwarded-host", "mtls.firezone.test")
        |> put_req_header("x-forwarded-proto", "https")
        |> Endpoint.call([])

      assert conn.status == 301
      assert get_resp_header(conn, "location") == ["https://api.firezone.test/client"]
      assert get_req_header(conn, "x-forwarded-host") == []
      assert get_req_header(conn, "x-forwarded-proto") == []
    end

    test "serves readiness checks without redirecting" do
      conn = Endpoint.call(conn(:get, "http://api.firezone.test/readyz"), [])

      assert conn.status in [200, 503]
      assert get_resp_header(conn, "location") == []
    end
  end

  describe "when a reverse proxy terminates TLS" do
    test "serves plain HTTP requests instead of redirecting" do
      conn = Endpoint.call(conn(:get, "http://api.firezone.test/client"), [])

      assert conn.private.phoenix_endpoint == PortalAPI.Endpoint
    end

    test "drops forwarded and geo headers while no proxy is trusted" do
      conn =
        :get
        |> conn("http://unknown.firezone.test/")
        |> put_req_header("x-forwarded-for", "1.2.3.4")
        |> put_req_header("x-forwarded-host", "app.firezone.test")
        |> put_req_header("x-azure-geo-country", "US")
        |> put_req_header("x-geo-location-region", "US")
        |> Endpoint.call([])

      assert conn.status == 404
      assert conn.remote_ip == {127, 0, 0, 1}
      assert get_req_header(conn, "x-forwarded-for") == []
      assert get_req_header(conn, "x-forwarded-host") == []
      assert get_req_header(conn, "x-azure-geo-country") == []
      assert get_req_header(conn, "x-geo-location-region") == []
    end

    test "takes the client, host and scheme from a trusted proxy" do
      trust_proxy({127, 0, 0, 1})

      conn =
        :get
        |> conn("http://portal.internal/not-found")
        |> put_req_header("x-forwarded-for", "1.2.3.4")
        |> put_req_header("x-forwarded-host", "app.firezone.test")
        |> put_req_header("x-forwarded-proto", "https")
        |> Endpoint.call([])

      assert conn.private.phoenix_endpoint == PortalWeb.Endpoint
      assert conn.scheme == :https
      assert conn.remote_ip == {1, 2, 3, 4}
    end

    test "ignores an address the client prepended before the proxy appended its own" do
      trust_proxy({127, 0, 0, 1})

      conn =
        :get
        |> conn("http://unknown.firezone.test/")
        |> put_req_header("x-forwarded-for", "6.6.6.6, 203.0.113.5")
        |> Endpoint.call([])

      assert conn.remote_ip == {203, 0, 113, 5}
    end

    test "skips further proxy hops on private addresses" do
      trust_proxy({127, 0, 0, 1})

      conn =
        :get
        |> conn("http://unknown.firezone.test/")
        |> put_req_header("x-forwarded-for", "6.6.6.6, 203.0.113.5, 10.0.0.1")
        |> Endpoint.call([])

      assert conn.remote_ip == {203, 0, 113, 5}
    end

    test "reports an IPv4 peer on a dual-stack listener as IPv4" do
      trust_proxy({127, 0, 0, 1})

      conn =
        :get
        |> conn("http://unknown.firezone.test/")
        |> Map.put(:remote_ip, {0, 0, 0, 0, 0, 0xFFFF, 0x7F00, 0x0001})
        |> put_req_header("x-forwarded-for", "::ffff:107.197.104.68:53859")
        |> Endpoint.call([])

      assert conn.remote_ip == {107, 197, 104, 68}
    end

    test "ignores forwarded headers on a request that skipped the proxy" do
      trust_proxy({10, 0, 0, 1})

      conn =
        :get
        |> conn("http://unknown.firezone.test/")
        |> put_req_header("x-forwarded-for", "6.6.6.6")
        |> put_req_header("x-forwarded-host", "app.firezone.test")
        |> Endpoint.call([])

      assert conn.status == 404
      assert conn.remote_ip == {127, 0, 0, 1}
      assert get_req_header(conn, "x-forwarded-for") == []
    end
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

  test "distinguishes the mutual-TLS endpoint by hostname and port" do
    Portal.Config.put_env_override(:portal, :web_external_url, "https://localhost:443/")
    Portal.Config.put_env_override(:portal, :mtls_external_url, "https://localhost:4444/")

    web = Endpoint.call(conn(:get, "https://localhost:443/not-found"), [])
    assert web.private.phoenix_endpoint == PortalWeb.Endpoint

    rejected = Endpoint.call(conn(:get, "https://localhost:4444/not-found"), [])
    assert rejected.status == 404
    assert rejected.private.phoenix_endpoint == Endpoint

    forwarded =
      :get
      |> conn("https://localhost:4444/not-found")
      |> put_req_header("upgrade", "websocket")
      |> Endpoint.call([])

    assert forwarded.private.phoenix_endpoint == PortalAPI.Endpoint

    wrong_port =
      :get
      |> conn("https://localhost:4445/not-found")
      |> put_req_header("upgrade", "websocket")
      |> Endpoint.call([])

    assert wrong_port.private.phoenix_endpoint == PortalWeb.Endpoint
  end

  test "rejects unknown hostnames" do
    conn = Endpoint.call(conn(:get, "https://unknown.firezone.test/"), [])

    assert conn.status == 404
    assert conn.private.phoenix_endpoint == Endpoint
  end

  defp trust_proxy(address) do
    Portal.Config.put_env_override(:portal, :external_trusted_proxies, [
      %Postgrex.INET{address: address, netmask: 32}
    ])
  end
end
