defmodule Web.Acceptance.Auth.OpenIDConnectTest do
  use Web.AcceptanceCase, async: true
  alias Domain.{AccountsFixtures, AuthFixtures}

  feature "returns error when identity did not exist", %{session: session} do
    account = AccountsFixtures.create_account()
    Vault.setup_oidc_provider(account, @endpoint.url)

    oidc_login = "firezone-1"
    oidc_password = "firezone1234_oidc"
    email = AuthFixtures.email()

    :ok = Vault.upsert_user(oidc_login, email, oidc_password)

    session
    |> visit(~p"/#{account}/sign_in")
    |> assert_el(Query.text("Welcome back"))
    |> click(Query.link("Log in with Vault"))
    |> Vault.userpass_flow(oidc_login, oidc_password)
    |> assert_el(Query.text("Welcome back"))
    |> assert_path(~p"/#{account}/sign_in")
    |> assert_el(Query.text("You can not authenticate to this account."))
  end

  feature "authenticates existing user", %{session: session} do
    account = AccountsFixtures.create_account()
    provider = Vault.setup_oidc_provider(account, @endpoint.url)

    oidc_login = "firezone-1"
    oidc_password = "firezone1234_oidc"
    email = AuthFixtures.email()

    identity =
      AuthFixtures.create_identity(
        account: account,
        provider: provider,
        actor_default_type: :account_admin_user,
        provider_identifier: email
      )

    :ok = Vault.upsert_user(oidc_login, email, oidc_password)

    session
    |> visit(~p"/#{account}/sign_in")
    |> assert_el(Query.text("Welcome back"))
    |> click(Query.link("Log in with Vault"))
    |> Vault.userpass_flow(oidc_login, oidc_password)
    |> assert_el(Query.css("#user-menu-button"))
    |> Auth.assert_authenticated(identity)
    |> assert_path(~p"/#{account}/dashboard")
  end
end
