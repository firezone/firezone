defmodule Web.Cookie.ClientAuthTest do
  use Web.ConnCase, async: true

  alias Web.Cookie.ClientAuth

  @cookie_key "client_auth"

  defp recycle_conn(conn) do
    cookie_value = conn.resp_cookies[@cookie_key].value

    build_conn()
    |> Map.put(:secret_key_base, Web.Endpoint.config(:secret_key_base))
    |> Plug.Test.put_req_cookie(@cookie_key, cookie_value)
  end

  describe "put/2 and fetch/1" do
    test "stores and retrieves cookie data", %{conn: conn} do
      cookie = %ClientAuth{
        actor_name: "Test User",
        fragment: "abc123fragment",
        identity_provider_identifier: "test@example.com",
        state: "oauth-state-123"
      }

      conn =
        conn
        |> ClientAuth.put(cookie)
        |> recycle_conn()

      result = ClientAuth.fetch(conn)

      assert %ClientAuth{} = result
      assert result.actor_name == "Test User"
      assert result.fragment == "abc123fragment"
      assert result.identity_provider_identifier == "test@example.com"
      assert result.state == "oauth-state-123"
    end

    test "handles nil state", %{conn: conn} do
      cookie = %ClientAuth{
        actor_name: "Test User",
        fragment: "abc123fragment",
        identity_provider_identifier: "test@example.com",
        state: nil
      }

      conn =
        conn
        |> ClientAuth.put(cookie)
        |> recycle_conn()

      result = ClientAuth.fetch(conn)

      assert %ClientAuth{} = result
      assert result.state == nil
    end

    test "returns nil when cookie is not present", %{conn: conn} do
      assert ClientAuth.fetch(conn) == nil
    end
  end
end
