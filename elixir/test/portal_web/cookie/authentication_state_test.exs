defmodule PortalWeb.Cookie.AuthenticationStateTest do
  use PortalWeb.ConnCase, async: true

  alias PortalWeb.Cookie.AuthenticationState

  describe "put/2 and fetch/1" do
    test "round-trips a cookie through put and fetch", %{conn: conn} do
      account_id = Ecto.UUID.generate()
      provider_id = Ecto.UUID.generate()

      cookie = %AuthenticationState{
        auth_provider_type: "oidc",
        auth_provider_id: provider_id,
        account_id: account_id,
        account_slug: "test-account",
        state: "some-state",
        verifier: "some-verifier",
        params: %{"as" => "client"}
      }

      result =
        conn
        |> Map.put(:secret_key_base, PortalWeb.Endpoint.config(:secret_key_base))
        |> AuthenticationState.put(cookie)
        |> recycle()
        |> Map.put(:secret_key_base, PortalWeb.Endpoint.config(:secret_key_base))
        |> AuthenticationState.fetch()

      assert result.auth_provider_type == "oidc"
      assert result.auth_provider_id == provider_id
      assert result.account_id == account_id
      assert result.account_slug == "test-account"
      assert result.state == "some-state"
      assert result.verifier == "some-verifier"
      assert result.params == %{"as" => "client"}
    end

    test "returns nil when no cookie is present", %{conn: conn} do
      assert AuthenticationState.fetch(conn) == nil
    end

    test "returns nil for a cookie with wrong-arity tuple content", %{conn: conn} do
      secret_key_base = PortalWeb.Endpoint.config(:secret_key_base)
      signing_salt = Portal.Config.fetch_env!(:portal, :cookie_signing_salt)
      cookie_secure = Portal.Config.fetch_env!(:portal, :cookie_secure)

      # A 1-tuple: binary_to_term succeeds but the case _ -> nil branch fires
      # because it doesn't match the expected 7-element tuple.
      bad_binary = :erlang.term_to_binary({:wrong_format})

      result =
        conn
        |> Map.put(:secret_key_base, secret_key_base)
        |> Plug.Conn.put_resp_cookie("oidc", bad_binary,
          sign: true,
          max_age: 5 * 60,
          same_site: "Lax",
          secure: cookie_secure,
          http_only: true,
          signing_salt: signing_salt
        )
        |> recycle()
        |> Map.put(:secret_key_base, secret_key_base)
        |> AuthenticationState.fetch()

      assert result == nil
    end

    test "returns nil for a cookie with invalid UUID bytes", %{conn: conn} do
      secret_key_base = PortalWeb.Endpoint.config(:secret_key_base)
      signing_salt = Portal.Config.fetch_env!(:portal, :cookie_signing_salt)
      cookie_secure = Portal.Config.fetch_env!(:portal, :cookie_secure)

      # A 7-tuple that matches the arity but has invalid UUID bytes (3 bytes instead of 16).
      # binary_to_term and the case match both succeed, but Ecto.UUID.load/1 returns :error,
      # triggering the with's else _ -> nil branch.
      bad_binary =
        :erlang.term_to_binary({"oidc", <<1, 2, 3>>, <<4, 5, 6>>, "slug", "state", "v", nil})

      result =
        conn
        |> Map.put(:secret_key_base, secret_key_base)
        |> Plug.Conn.put_resp_cookie("oidc", bad_binary,
          sign: true,
          max_age: 5 * 60,
          same_site: "Lax",
          secure: cookie_secure,
          http_only: true,
          signing_salt: signing_salt
        )
        |> recycle()
        |> Map.put(:secret_key_base, secret_key_base)
        |> AuthenticationState.fetch()

      assert result == nil
    end
  end

  describe "delete/1" do
    test "marks the cookie for expiration", %{conn: conn} do
      account_id = Ecto.UUID.generate()
      provider_id = Ecto.UUID.generate()

      cookie = %AuthenticationState{
        auth_provider_type: "oidc",
        auth_provider_id: provider_id,
        account_id: account_id,
        account_slug: "test-account",
        state: "some-state",
        verifier: "some-verifier"
      }

      conn =
        conn
        |> Map.put(:secret_key_base, PortalWeb.Endpoint.config(:secret_key_base))
        |> AuthenticationState.put(cookie)
        |> AuthenticationState.delete()

      assert conn.resp_cookies["oidc"].max_age == 0
    end
  end
end
