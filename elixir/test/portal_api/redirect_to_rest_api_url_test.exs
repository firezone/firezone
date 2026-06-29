defmodule PortalAPI.RedirectToRestApiUrlTest do
  use ExUnit.Case, async: true

  import Plug.Test
  import Plug.Conn

  alias PortalAPI.Endpoint

  defp call(conn) do
    Endpoint.redirect_to_rest_api_url(conn, [])
  end

  describe "redirect_to_rest_api_url/2" do
    test "passes through when rest_api_url is not configured" do
      conn = conn(:get, "https://api.firezone.dev/clients")

      result = call(conn)

      assert result == conn
      refute result.halted
    end

    test "passes through when the request host already matches rest_api_url" do
      Portal.Config.put_env_override(:rest_api_url, "https://rest-api.firezone.dev/")

      conn = conn(:get, "https://rest-api.firezone.dev/clients?limit=5")

      result = call(conn)

      refute result.halted
      assert result == conn
    end

    test "permanent-redirects requests on any other host preserving path and query" do
      Portal.Config.put_env_override(:rest_api_url, "https://rest-api.firezone.dev/")

      conn = conn(:get, "https://api.firezone.dev/clients?limit=5")

      result = call(conn)

      assert result.halted
      assert result.status == 308

      assert get_resp_header(result, "location") ==
               ["https://rest-api.firezone.dev/clients?limit=5"]
    end

    test "preserves the request method for non-GET requests" do
      Portal.Config.put_env_override(:rest_api_url, "https://rest-api.firezone.dev/")

      conn = conn(:post, "https://api.firezone.dev/clients", "")

      result = call(conn)

      assert result.halted
      assert result.status == 308
      assert get_resp_header(result, "location") == ["https://rest-api.firezone.dev/clients"]
    end

    test "redirects before authentication, ignoring request headers" do
      Portal.Config.put_env_override(:rest_api_url, "https://rest-api.firezone.dev/")

      conn =
        conn(:get, "https://api.firezone.dev/clients")
        |> put_req_header("authorization", "Bearer some-token")

      result = call(conn)

      assert result.halted
      assert result.status == 308
      assert get_resp_header(result, "location") == ["https://rest-api.firezone.dev/clients"]
    end

    test "sends an empty body, leaving the client to replay the request" do
      Portal.Config.put_env_override(:rest_api_url, "https://rest-api.firezone.dev/")

      conn = conn(:post, "https://api.firezone.dev/clients", "request body")

      result = call(conn)

      assert result.status == 308
      assert result.resp_body == ""
    end

    test "redirects to the configured staging host" do
      Portal.Config.put_env_override(:rest_api_url, "https://rest-api.firez.one/")

      conn = conn(:get, "https://api.firez.one/account")

      result = call(conn)

      assert result.halted
      assert result.status == 308
      assert get_resp_header(result, "location") == ["https://rest-api.firez.one/account"]
    end
  end
end
