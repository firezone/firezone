defmodule PortalWeb.SignInTest do
  use PortalWeb.ConnCase, async: true

  import Portal.AccountFixtures
  import Portal.AuthProviderFixtures

  test "renders active providers on the page", %{conn: conn} do
    Portal.Config.put_env_override(:outbound_email_adapter_configured?, true)

    account = account_fixture()

    email_otp_provider_fixture(account: account)

    {:ok, _lv, html} = live(conn, ~p"/#{account}")

    assert html =~ "Sign in with email"
    refute html =~ "Sign in with username and password"

    userpass_provider_fixture(account: account)

    {:ok, _lv, html} = live(conn, ~p"/#{account}")

    assert html =~ "Sign in with username and password"
    refute html =~ "Vault"

    oidc_provider_fixture(account: account, name: "Vault")

    {:ok, _lv, html} = live(conn, ~p"/#{account}")

    assert html =~ "Vault"
  end

  test "keeps client auth params", %{conn: conn} do
    Portal.Config.put_env_override(:outbound_email_adapter_configured?, true)
    account = account_fixture()
    email_otp_provider_fixture(account: account)

    {:ok, _lv, html} = live(conn, ~p"/#{account}?as=client&nonce=NONCE&state=STATE")

    assert html =~ ~s|value="NONCE"|
    assert html =~ ~s|value="STATE"|
    assert html =~ ~s|value="client"|
  end

  test "renders error when account is disabled", %{conn: conn} do
    Portal.Config.put_env_override(:outbound_email_adapter_configured?, true)
    account = account_fixture()

    account = update_account(account, %{disabled_at: DateTime.utc_now()})

    email_otp_provider_fixture(account: account)
    {:ok, _lv, html} = live(conn, ~p"/#{account}")

    assert html =~
             "This account has been disabled. Please contact your administrator to re-enable it."
  end
end
