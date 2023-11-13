defmodule Web.Acceptance.Auth.OpenIDConnectTest do
  use Web.AcceptanceCase, async: true

  feature "returns error when identity did not exist", %{session: session} do
    account = Fixtures.Accounts.create_account()
    Vault.setup_oidc_provider(account, @endpoint.url)

    oidc_login = "firezone-1"
    oidc_password = "firezone1234_oidc"
    email = Fixtures.Auth.email()

    {:ok, _entity_id} = Vault.upsert_user(oidc_login, email, oidc_password)

    session
    |> visit(~p"/#{account}")
    |> assert_el(Query.text("#{account.name} Admin Portal"))
    |> click(Query.link("Sign in with Vault"))
    |> Vault.userpass_flow(oidc_login, oidc_password)
    |> assert_el(Query.text("#{account.name} Admin Portal"))
    |> assert_path(~p"/#{account.id}")
    |> assert_el(Query.text("You may not authenticate to this account."))
  end

  feature "authenticates existing user", %{session: session} do
    account = Fixtures.Accounts.create_account()
    provider = Vault.setup_oidc_provider(account, @endpoint.url)

    oidc_login = "firezone-1"
    oidc_password = "firezone1234_oidc"
    email = Fixtures.Auth.email()

    {:ok, entity_id} = Vault.upsert_user(oidc_login, email, oidc_password)

    identity =
      Fixtures.Auth.create_identity(
        actor: [type: :account_admin_user],
        account: account,
        provider: provider,
        provider_identifier: entity_id
      )

    session
    |> visit(~p"/#{account}")
    |> assert_el(Query.text("#{account.name} Admin Portal"))
    |> click(Query.link("Sign in with Vault"))
    |> Vault.userpass_flow(oidc_login, oidc_password)
    |> assert_el(Query.css("#user-menu-button"))
    |> Auth.assert_authenticated(identity)
    |> assert_path(~p"/#{account.slug}/sites")
  end
end
