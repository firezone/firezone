defmodule PortalWeb.Cookie.OIDCTest do
  use PortalWeb.ConnCase, async: true

  alias PortalWeb.Cookie.OIDC

  defp recycle_conn(conn, cookie_key \\ "oidc") do
    cookie_value = conn.resp_cookies[cookie_key].value

    build_conn()
    |> Map.put(:secret_key_base, PortalWeb.Endpoint.config(:secret_key_base))
    |> Plug.Test.put_req_cookie(cookie_key, cookie_value)
  end

  describe "put/2 and fetch/1" do
    test "stores and retrieves cookie data", %{conn: conn} do
      auth_provider_id = Ecto.UUID.generate()
      account_id = Ecto.UUID.generate()

      cookie = %OIDC{
        auth_provider_type: "openid_connect",
        auth_provider_id: auth_provider_id,
        account_id: account_id,
        account_slug: "test-account",
        state: "oauth-state-123",
        verifier: "pkce-verifier-456",
        params: %{"as" => "client", "redirect_to" => "/dashboard"}
      }

      conn =
        conn
        |> OIDC.put(cookie)
        |> recycle_conn()

      result = OIDC.fetch(conn)

      assert %OIDC{} = result
      assert result.auth_provider_type == "openid_connect"
      assert result.auth_provider_id == auth_provider_id
      assert result.account_id == account_id
      assert result.account_slug == "test-account"
      assert result.state == "oauth-state-123"
      assert result.verifier == "pkce-verifier-456"
      assert result.params == %{"as" => "client", "redirect_to" => "/dashboard"}
    end

    test "handles nil params", %{conn: conn} do
      cookie = %OIDC{
        auth_provider_type: "openid_connect",
        auth_provider_id: Ecto.UUID.generate(),
        account_id: Ecto.UUID.generate(),
        account_slug: "test-account",
        state: "oauth-state-123",
        verifier: "pkce-verifier-456",
        params: nil
      }

      conn =
        conn
        |> OIDC.put(cookie)
        |> recycle_conn()

      result = OIDC.fetch(conn)

      assert %OIDC{} = result
      assert result.params == nil
    end

    test "returns nil when cookie is not present", %{conn: conn} do
      assert OIDC.fetch(conn) == nil
    end
  end

  describe "delete/1" do
    test "removes the cookie", %{conn: conn} do
      cookie = %OIDC{
        auth_provider_type: "openid_connect",
        auth_provider_id: Ecto.UUID.generate(),
        account_id: Ecto.UUID.generate(),
        account_slug: "test-account",
        state: "oauth-state-123",
        verifier: "pkce-verifier-456",
        params: nil
      }

      # First put the cookie and recycle
      conn = conn |> OIDC.put(cookie) |> recycle_conn()

      # Verify cookie is present
      assert OIDC.fetch(conn) != nil

      # Delete the cookie - after delete the cookie is marked for expiration
      conn = OIDC.delete(conn)
      assert conn.resp_cookies["oidc"].max_age == 0
    end
  end
end
