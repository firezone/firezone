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
        params = "as=#{client}&state=abc&nonce=xyz&redirect_to=%2Fsites"

        conn = get(conn, "/some-account?#{params}")

        assert redirected_to(conn) == "/some-account/sign_in?#{params}"
      end
    end
  end
end
