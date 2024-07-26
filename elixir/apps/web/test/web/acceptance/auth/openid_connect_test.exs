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
    |> assert_el(Query.text("#{account.name}"))
    |> click(Query.link("Sign in with Vault"))
    |> Vault.userpass_flow(oidc_login, oidc_password)
    |> assert_el(Query.text("#{account.name}"))
    |> assert_path(~p"/#{account.id}")
    |> assert_el(Query.text("You may not authenticate to this account."))
  end

  feature "authenticates a user to a portal", %{session: session} do
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
    |> assert_el(Query.text("#{account.name}"))
    |> click(Query.link("Sign in with Vault"))
    |> Vault.userpass_flow(oidc_login, oidc_password)
    |> assert_el(Query.css("#user-menu-button"))
    |> Auth.assert_authenticated(identity)
    |> assert_path(~p"/#{account.slug}/sites")
  end

  feature "authenticates an invited user to a portal using email claim", %{session: session} do
    account = Fixtures.Accounts.create_account()
    provider = Vault.setup_oidc_provider(account, @endpoint.url)

    oidc_login = "firezone-1"
    oidc_password = "firezone1234_oidc"
    email = Fixtures.Auth.email()

    {:ok, _entity_id} = Vault.upsert_user(oidc_login, email, oidc_password)

    identity =
      Fixtures.Auth.create_identity(
        actor: [type: :account_admin_user],
        account: account,
        provider: provider,
        provider_identifier: email
      )

    session
    |> visit(~p"/#{account}")
    |> assert_el(Query.text("#{account.name}"))
    |> click(Query.link("Sign in with Vault"))
    |> Vault.userpass_flow(oidc_login, oidc_password)
    |> assert_el(Query.css("#user-menu-button"))
    |> Auth.assert_authenticated(identity)
    |> assert_path(~p"/#{account.slug}/sites")
  end

  feature "authenticates a user to a client", %{session: session} do
    nonce = Ecto.UUID.generate()
    state = Ecto.UUID.generate()

    Auth.mock_client_sign_in_callback()

    redirect_params = %{
      "as" => "client",
      "state" => "state_#{state}",
      "nonce" => "nonce_#{nonce}"
    }

    account = Fixtures.Accounts.create_account()
    provider = Vault.setup_oidc_provider(account, @endpoint.url)

    oidc_login = "firezone-1"
    oidc_password = "firezone1234_oidc"
    email = Fixtures.Auth.email()

    {:ok, entity_id} = Vault.upsert_user(oidc_login, email, oidc_password)

    actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)

    identity =
      Fixtures.Auth.create_identity(
        actor: actor,
        account: account,
        provider: provider,
        provider_identifier: entity_id
      )

    session
    |> visit(~p"/#{account}?#{redirect_params}")
    |> assert_el(Query.text("#{account.name}"))
    |> click(Query.link("Sign in with Vault"))
    |> Vault.userpass_flow(oidc_login, oidc_password)
    |> assert_el(Query.text("Client redirected"))
    |> assert_path(~p"/handle_client_sign_in_callback")

    assert_received {:handle_client_sign_in_callback,
                     %{
                       "account_name" => account_name,
                       "account_slug" => account_slug,
                       "actor_name" => actor_name,
                       "fragment" => fragment,
                       "identity_provider_identifier" => identity_provider_identifier,
                       "state" => state
                     }}

    assert account_name == account.name
    assert account_slug == account.slug
    assert actor_name == actor.name
    assert identity_provider_identifier == identity.provider_identifier
    assert state == redirect_params["state"]

    context = Fixtures.Auth.build_context(type: :client)
    token = redirect_params["nonce"] <> fragment
    assert Domain.Auth.authenticate(fragment, context) == {:error, :unauthorized}
    assert Domain.Auth.authenticate(redirect_params["nonce"], context) == {:error, :unauthorized}
    assert {:ok, _subject} = Domain.Auth.authenticate(token, context)
  end

  feature "allows to sign in to the browser and then to the client", %{
    session: session
  } do
    nonce = Ecto.UUID.generate()
    state = Ecto.UUID.generate()

    Auth.mock_client_sign_in_callback()

    redirect_params = %{
      "as" => "client",
      "state" => "state_#{state}",
      "nonce" => "nonce_#{nonce}"
    }

    account = Fixtures.Accounts.create_account()
    provider = Vault.setup_oidc_provider(account, @endpoint.url)

    oidc_login = "firezone-1"
    oidc_password = "firezone1234_oidc"
    email = Fixtures.Auth.email()

    {:ok, entity_id} = Vault.upsert_user(oidc_login, email, oidc_password)

    actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)

    identity =
      Fixtures.Auth.create_identity(
        actor: actor,
        account: account,
        provider: provider,
        provider_identifier: entity_id
      )

    # Sign In as a portal user
    session
    |> visit(~p"/#{account}")
    |> assert_el(Query.text("#{account.name}"))
    |> click(Query.link("Sign in with Vault"))
    |> Vault.userpass_flow(oidc_login, oidc_password)
    |> assert_el(Query.css("#user-menu-button"))
    |> Auth.assert_authenticated(identity)
    |> assert_path(~p"/#{account.slug}/sites")

    # And then to a client
    session
    |> visit(~p"/#{account}?#{redirect_params}")
    |> assert_el(Query.text("#{account.name}"))
    |> click(Query.link("Sign in with Vault"))
    |> assert_el(Query.text("Client redirected"))
    |> assert_path(~p"/handle_client_sign_in_callback")

    # The browser sessions stays active
    session
    |> visit(~p"/#{account}/sites")
    |> assert_el(Query.css("#user-menu-button"))

    # Browser session is stored correctly
    {:ok, cookie} = Auth.fetch_session_cookie(session)
    assert [{:browser, account_id, _fragment}] = cookie["sessions"]
    assert account_id == account.id
  end

  feature "allows to sign in to the client and then to the browser", %{
    session: session
  } do
    nonce = Ecto.UUID.generate()
    state = Ecto.UUID.generate()

    Auth.mock_client_sign_in_callback()

    redirect_params = %{
      "as" => "client",
      "state" => "state_#{state}",
      "nonce" => "nonce_#{nonce}"
    }

    account = Fixtures.Accounts.create_account()
    provider = Vault.setup_oidc_provider(account, @endpoint.url)

    oidc_login = "firezone-1"
    oidc_password = "firezone1234_oidc"
    email = Fixtures.Auth.email()

    {:ok, entity_id} = Vault.upsert_user(oidc_login, email, oidc_password)

    actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)

    identity =
      Fixtures.Auth.create_identity(
        actor: actor,
        account: account,
        provider: provider,
        provider_identifier: entity_id
      )

    # And then to a client
    session
    |> visit(~p"/#{account}?#{redirect_params}")
    |> assert_el(Query.text("#{account.name}"))
    |> click(Query.link("Sign in with Vault"))
    |> Vault.userpass_flow(oidc_login, oidc_password)
    |> assert_el(Query.text("Client redirected"))
    |> assert_path(~p"/handle_client_sign_in_callback")

    # Sign In as an portal user
    session
    |> visit(~p"/#{account}")
    |> assert_el(Query.text("#{account.name}"))
    |> click(Query.link("Sign in with Vault"))
    |> assert_el(Query.css("#user-menu-button"))
    |> Auth.assert_authenticated(identity)
    |> assert_path(~p"/#{account.slug}/sites")

    # The browser sessions stays active
    session
    |> visit(~p"/#{account}/sites")
    |> assert_el(Query.css("#user-menu-button"))

    # Browser session is stored correctly
    {:ok, cookie} = Auth.fetch_session_cookie(session)
    assert [{:browser, account_id, _fragment}] = cookie["sessions"]
    assert account_id == account.id
  end
end
