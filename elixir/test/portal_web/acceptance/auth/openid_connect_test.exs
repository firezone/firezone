defmodule PortalWeb.Acceptance.Auth.OpenIDConnectTest do
  use PortalWeb.AcceptanceCase, async: true

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.IdentityFixtures

  alias PortalWeb.AcceptanceCase.Auth

  feature "returns error when identity did not exist", %{session: session} do
    account = account_fixture()
    provider = Vault.setup_oidc_provider(account, @endpoint.url())

    oidc_login = "firezone-1"
    oidc_password = "firezone1234_oidc"
    email = "firezone-1@example.com"

    {:ok, _entity_id} = Vault.upsert_user(oidc_login, email, oidc_password)

    session
    |> visit(~p"/#{account}")
    |> assert_el(Query.text("#{account.name}"))
    |> click(Query.link("Sign in with #{provider.name}"))
    |> Vault.userpass_flow(oidc_login, oidc_password)
    |> assert_el(Query.text("#{account.name}"))
    |> assert_path(~p"/#{account.id}")
    |> assert_el(Query.text("You may not authenticate to this account."))
  end

  feature "authenticates a user to a portal", %{session: session} do
    account = account_fixture()
    provider = Vault.setup_oidc_provider(account, @endpoint.url())

    oidc_login = "firezone-1"
    oidc_password = "firezone1234_oidc"
    email = "firezone-1@example.com"

    {:ok, entity_id} = Vault.upsert_user(oidc_login, email, oidc_password)

    actor = actor_fixture(account: account, type: :account_admin_user)

    _identity =
      identity_fixture(
        actor: actor,
        account: account,
        issuer: "#{provider.issuer}",
        idp_id: entity_id
      )

    session
    |> visit(~p"/#{account}")
    |> assert_el(Query.text("#{account.name}"))
    |> click(Query.link("Sign in with #{provider.name}"))
    |> Vault.userpass_flow(oidc_login, oidc_password)
    |> assert_el(Query.css("#user-menu-button"))
    |> Auth.assert_authenticated(actor)
    |> assert_path(~p"/#{account.slug}/sites")
  end

  feature "authenticates an invited user to a portal using email claim", %{session: session} do
    account = account_fixture()
    provider = Vault.setup_oidc_provider(account, @endpoint.url())

    oidc_login = "firezone-1"
    oidc_password = "firezone1234_oidc"
    email = "firezone-1@example.com"

    {:ok, _entity_id} = Vault.upsert_user(oidc_login, email, oidc_password)

    actor = actor_fixture(account: account, type: :account_admin_user)

    _identity =
      identity_fixture(
        actor: actor,
        account: account,
        issuer: "#{provider.issuer}",
        idp_id: email
      )

    session
    |> visit(~p"/#{account}")
    |> assert_el(Query.text("#{account.name}"))
    |> click(Query.link("Sign in with #{provider.name}"))
    |> Vault.userpass_flow(oidc_login, oidc_password)
    |> assert_el(Query.css("#user-menu-button"))
    |> Auth.assert_authenticated(actor)
    |> assert_path(~p"/#{account.slug}/sites")
  end

  feature "authenticates a user to a client", %{session: session} do
    nonce = Ecto.UUID.generate()
    state = Ecto.UUID.generate()

    bypass = Auth.mock_client_sign_in_callback()

    redirect_params = %{
      "as" => "client",
      "state" => "state_#{state}",
      "nonce" => "nonce_#{nonce}"
    }

    account = account_fixture()
    provider = Vault.setup_oidc_provider(account, @endpoint.url())

    oidc_login = "firezone-1"
    oidc_password = "firezone1234_oidc"
    email = "firezone-1@example.com"

    {:ok, entity_id} = Vault.upsert_user(oidc_login, email, oidc_password)

    actor = actor_fixture(account: account, type: :account_admin_user)

    _identity =
      identity_fixture(
        actor: actor,
        account: account,
        issuer: "#{provider.issuer}",
        idp_id: entity_id
      )

    session
    |> visit(~p"/#{account}?#{redirect_params}")
    |> assert_el(Query.text("#{account.name}"))
    |> click(Query.link("Sign in with #{provider.name}"))
    |> Vault.userpass_flow(oidc_login, oidc_password)
    |> assert_el(Query.text("Client redirected"))
    |> assert_path(~p"/handle_client_sign_in_callback")

    assert_received {:handle_client_sign_in_callback,
                     %{
                       "account_name" => account_name,
                       "account_slug" => account_slug,
                       "actor_name" => actor_name,
                       "state" => received_state
                     }}

    assert account_name == account.name
    assert account_slug == account.slug
    assert actor_name == actor.name
    assert received_state == redirect_params["state"]

    Bypass.down(bypass)
  end
end
