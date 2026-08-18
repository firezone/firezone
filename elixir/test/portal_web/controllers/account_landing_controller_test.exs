defmodule PortalWeb.AccountLandingControllerTest do
  use PortalWeb.ConnCase, async: true

  @client_sign_in_types ["client", "gui-client", "headless-client"]

  describe "redirect_to_sign_in/2" do
    test "redirects /:account/ to /:account/sign_in", %{conn: conn} do
      conn = get(conn, ~p"/some-account")
      assert redirected_to(conn) == "/some-account/sign_in"
    end

    test "redirects client sign-in with slug to /:account/sign_in and preserves all sign-in params",
         %{conn: conn} do
      for client <- @client_sign_in_types do
        params = %{
          "as" => client,
          "state" => "abc",
          "nonce" => "xyz",
          "redirect_to" => "/sites"
        }

        conn = get(conn, ~p"/some-account?#{params}")

        assert redirected_to(conn) == ~p"/some-account/sign_in?#{params}"
      end
    end

    test "preserves campaign params", %{conn: conn} do
      params = %{
        "utm_source" => "email",
        "utm_medium" => "newsletter",
        "utm_campaign" => "spring",
        "utm_term" => "vpn",
        "utm_content" => "cta"
      }

      conn = get(conn, ~p"/some-account?#{params}")

      assert redirected_to(conn) == ~p"/some-account/sign_in?#{params}"
    end

    test "drops query params that are neither sign-in nor campaign params", %{conn: conn} do
      params = %{"as" => "client", "utm_source" => "email", "gclid" => "abc123"}

      conn = get(conn, ~p"/some-account?#{params}")

      assert redirected_to(conn) ==
               ~p"/some-account/sign_in?#{%{"as" => "client", "utm_source" => "email"}}"
    end

    test "redirects without raising when a scanner sends an unsafe query string", %{conn: conn} do
      conn = get(conn, "/some-account?fccc%27\\%22%3E%3Csvg/onload=alert(/xss/)%3E")

      assert redirected_to(conn) == "/some-account/sign_in"
    end

    test "escapes sign-in params taken from the query string", %{conn: conn} do
      conn = get(conn, ~p"/some-account?#{%{"redirect_to" => "/sites\\\"><svg/onload=alert(1)>"}}")

      redirect_path = redirected_to(conn)

      assert redirect_path == ~p"/some-account/sign_in?#{%{"redirect_to" => "/sites\\\"><svg/onload=alert(1)>"}}"
      refute redirect_path =~ "<svg"
    end
  end
end
