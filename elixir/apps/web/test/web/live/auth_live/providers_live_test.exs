defmodule Web.Auth.ProvidersLiveTest do
  use Web.ConnCase, async: true
  alias Domain.{AccountsFixtures, AuthFixtures}

  test "renders active providers on the page", %{conn: conn} do
    account = AccountsFixtures.create_account()

    email_provider = AuthFixtures.create_email_provider(account: account)

    {:ok, _lv, html} = live(conn, ~p"/#{account}/sign_in")

    assert html =~ "Sign in with a magic link"
    refute html =~ "Sign in with username and password"

    userpass_provider = AuthFixtures.create_userpass_provider(account: account)

    {:ok, _lv, html} = live(conn, ~p"/#{account}/sign_in")

    assert html =~ "Sign in with username and password"
    refute html =~ "Vault"

    AuthFixtures.start_openid_providers(["vault"])
    |> AuthFixtures.create_openid_connect_provider(name: "Vault", account: account)

    {:ok, _lv, html} = live(conn, ~p"/#{account}/sign_in")

    assert html =~ "Vault"

    identity =
      AuthFixtures.create_identity(
        actor_default_type: :account_admin_user,
        account: account,
        provider: email_provider
      )

    subject = AuthFixtures.create_subject(identity)

    {:ok, _provider} = Domain.Auth.disable_provider(userpass_provider, subject)
    {:ok, _lv, html} = live(conn, ~p"/#{account}/sign_in")
    refute html =~ "Sign in with username and password"

    {:ok, _provider} = Domain.Auth.delete_provider(email_provider, subject)
    {:ok, _lv, html} = live(conn, ~p"/#{account}/sign_in")
    refute html =~ "Sign in with a magic link"

    assert html =~ "Vault"
  end
end
