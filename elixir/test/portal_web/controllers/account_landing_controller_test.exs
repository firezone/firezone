defmodule PortalWeb.AccountLandingControllerTest do
  use PortalWeb.ConnCase, async: true

  describe "redirect_to_sign_in/2" do
    test "redirects /:account/ to /:account/sign_in", %{conn: conn} do
      conn = get(conn, ~p"/some-account")
      assert redirected_to(conn) == "/some-account/sign_in"
    end

    test "preserves query params on redirect", %{conn: conn} do
      conn = get(conn, "/some-account?as=client&state=abc&nonce=xyz")
      assert redirected_to(conn) == "/some-account/sign_in?as=client&state=abc&nonce=xyz"
    end

    test "preserves gui-client params on redirect", %{conn: conn} do
      conn = get(conn, "/some-account?as=gui-client&state=test-state&nonce=test-nonce")

      assert redirected_to(conn) ==
               "/some-account/sign_in?as=gui-client&state=test-state&nonce=test-nonce"
    end
  end
end
