defmodule PortalWeb.SignIn.SupportTest do
  use PortalWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Portal.AccountFixtures
  import Portal.AuthProviderFixtures
  import Portal.SupportAdminFixtures

  setup do
    account = account_fixture()
    provider = firezone_support_provider_fixture(account: account)
    {:ok, account: account, provider: provider}
  end

  defp put_support_cookie(conn, cookie) do
    conn = PortalWeb.Cookie.Support.put(conn, cookie)
    cookie_value = conn.resp_cookies["fz_support"].value
    put_req_cookie(build_conn(), "fz_support", cookie_value)
  end

  describe ":email" do
    test "404s when the account has no support provider", %{conn: conn} do
      other_account = account_fixture()

      assert_error_sent 404, fn ->
        live(conn, ~p"/#{other_account.slug}/support")
      end
    end

    test "404s when the provider is expired", %{conn: conn} do
      other_account = account_fixture()

      firezone_support_provider_fixture(
        account: other_account,
        expires_at: DateTime.add(DateTime.utc_now(), -60, :second)
      )

      assert_error_sent 404, fn ->
        live(conn, ~p"/#{other_account.slug}/support")
      end
    end

    test "renders the email form with sign-in params", %{conn: conn, account: account} do
      {:ok, _lv, html} =
        live(conn, ~p"/#{account.slug}/support?as=client&state=STATE&nonce=NONCE")

      assert html =~ "Firezone Support"
      assert html =~ ~s(action="/#{account.slug}/support")
      assert html =~ ~s(value="STATE")
      assert html =~ ~s(value="NONCE")
    end
  end

  describe ":verify_otp" do
    test "redirects to the start without a cookie", %{conn: conn, account: account} do
      {:error, {:redirect, %{to: to}}} = live(conn, ~p"/#{account.slug}/support/verify")
      assert to =~ ~p"/#{account.slug}/support"
    end

    test "renders the code entry form with a valid cookie", %{conn: conn, account: account} do
      {support_admin, _authenticator} = registered_support_admin_fixture()

      conn =
        put_support_cookie(conn, %PortalWeb.Cookie.Support{
          account_id: account.id,
          email: support_admin.email,
          stage: :otp
        })

      {:ok, _lv, html} = live(conn, ~p"/#{account.slug}/support/verify")

      assert html =~ support_admin.email
      assert html =~ "Verify code"
      assert html =~ "Resend email"
    end

    test "redirects when the cookie belongs to another account", %{conn: conn, account: account} do
      other_account = account_fixture()

      conn =
        put_support_cookie(conn, %PortalWeb.Cookie.Support{
          account_id: other_account.id,
          email: "someone@firezone.dev",
          stage: :otp
        })

      {:error, {:redirect, %{to: to}}} = live(conn, ~p"/#{account.slug}/support/verify")
      assert to =~ ~p"/#{account.slug}/support"
    end
  end

  describe ":passkey" do
    test "redirects when the cookie is still at the OTP stage", %{conn: conn, account: account} do
      conn =
        put_support_cookie(conn, %PortalWeb.Cookie.Support{
          account_id: account.id,
          email: "someone@firezone.dev",
          stage: :otp
        })

      {:error, {:redirect, %{to: to}}} = live(conn, ~p"/#{account.slug}/support/passkey")
      assert to =~ ~p"/#{account.slug}/support"
    end

    test "renders the passkey ceremony with a passkey-stage cookie", %{
      conn: conn,
      account: account
    } do
      {support_admin, authenticator} = registered_support_admin_fixture()

      challenge =
        Portal.Crypto.WebAuthn.authentication_challenge(
          authenticator.credential_id,
          authenticator.cose_key
        )

      conn =
        put_support_cookie(conn, %PortalWeb.Cookie.Support{
          account_id: account.id,
          email: support_admin.email,
          stage: :passkey,
          challenge: challenge
        })

      {:ok, _lv, html} = live(conn, ~p"/#{account.slug}/support/passkey")

      assert html =~ "Use passkey"
      assert html =~ ~s(action="/#{account.slug}/support/complete")

      assert html =~
               ~s(data-challenge="#{Base.url_encode64(challenge.bytes, padding: false)}")

      assert html =~
               ~s(data-credential-id="#{Base.url_encode64(authenticator.credential_id, padding: false)}")
    end
  end
end
