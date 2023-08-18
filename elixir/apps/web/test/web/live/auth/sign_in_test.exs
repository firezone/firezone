defmodule Web.Auth.SignInTest do
  use Web.ConnCase, async: true

  test "renders active providers on the page", %{conn: conn} do
    Domain.Config.put_system_env_override(:outbound_email_adapter, Swoosh.Adapters.Postmark)

    account = Fixtures.Accounts.create_account()

    email_provider = Fixtures.Auth.create_email_provider(account: account)

    {:ok, _lv, html} = live(conn, ~p"/#{account}/sign_in")

    assert html =~ "Sign in with a magic link"
    refute html =~ "Sign in with username and password"

    userpass_provider = Fixtures.Auth.create_userpass_provider(account: account)

    {:ok, _lv, html} = live(conn, ~p"/#{account}/sign_in")

    assert html =~ "Sign in with username and password"
    refute html =~ "Vault"

    Fixtures.Auth.start_and_create_openid_connect_provider(name: "Vault", account: account)

    {:ok, _lv, html} = live(conn, ~p"/#{account}/sign_in")

    assert html =~ "Vault"

    identity =
      Fixtures.Auth.create_identity(
        actor_default_type: :account_admin_user,
        account: account,
        provider: email_provider
      )

    subject = Fixtures.Auth.create_subject(identity)

    {:ok, _provider} = Domain.Auth.disable_provider(userpass_provider, subject)
    {:ok, _lv, html} = live(conn, ~p"/#{account}/sign_in")
    refute html =~ "Sign in with username and password"

    {:ok, _provider} = Domain.Auth.delete_provider(email_provider, subject)
    {:ok, _lv, html} = live(conn, ~p"/#{account}/sign_in")
    refute html =~ "Sign in with a magic link"

    assert html =~ "Vault"
  end
end
