defmodule PortalWeb.SignInTest do
  use PortalWeb.ConnCase, async: true

  import Portal.AccountFixtures
  import Portal.AuthProviderFixtures

  @client_sign_in_types ["client", "gui-client", "headless-client"]

  setup do
    account = account_fixture()
    %{account: account}
  end

  describe "mount" do
    test "renders sign-in page with account name", %{conn: conn, account: account} do
      {:ok, _lv, html} = live(conn, ~p"/#{account}/sign_in")

      assert html =~ "Sign in to #{account.name}"
    end

    test "renders email OTP form when email OTP provider is configured",
         %{conn: conn, account: account} do
      _provider = email_otp_provider_fixture(account: account)

      {:ok, _lv, html} = live(conn, ~p"/#{account}/sign_in")

      assert html =~ "Send code"
    end

    test "does not show email OTP form when no providers configured",
         %{conn: conn, account: account} do
      {:ok, _lv, html} = live(conn, ~p"/#{account}/sign_in")

      refute html =~ "Send code"
    end

    test "redirects missing client account slug to root /sign_in with params preserved", %{conn: conn} do
      for client <- @client_sign_in_types do
        params = %{
          "as" => client,
          "state" => "abc",
          "nonce" => "xyz",
          "redirect_to" => "/sites"
        }

        conn = get(conn, ~p"/nonexistent-account/sign_in?#{params}")
        assert redirected_to(conn) == ~p"/sign_in?#{params}"
      end
    end
  end
end
