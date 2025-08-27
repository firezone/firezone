defmodule Web.Acceptance.Auth.UserPassTest do
  use Web.AcceptanceCase, async: true

  feature "renders error on invalid login or password", %{session: session} do
    account = Fixtures.Accounts.create_account()
    provider = Fixtures.Auth.create_userpass_provider(account: account)
    password = "Firezone1234"

    identity =
      Fixtures.Auth.create_identity(
        account: account,
        provider: provider,
        provider_virtual_state: %{"password" => password, "password_confirmation" => password}
      )

    session
    |> password_login_flow(account, identity.provider_identifier, "invalid")
    |> assert_error_flash("Invalid username or password.")
    |> password_login_flow(account, "invalid@example.com", password)
    |> assert_error_flash("Invalid username or password.")
  end

  feature "renders error on if identity is disabled", %{session: session} do
    account = Fixtures.Accounts.create_account()
    provider = Fixtures.Auth.create_userpass_provider(account: account)
    password = "Firezone1234"

    identity =
      Fixtures.Auth.create_identity(
        account: account,
        provider: provider,
        provider_virtual_state: %{"password" => password, "password_confirmation" => password}
      )
      |> Fixtures.Auth.delete_identity()

    session
    |> password_login_flow(account, identity.provider_identifier, password)
    |> assert_error_flash("Invalid username or password.")
  end

  feature "renders error on if actor is disabled", %{session: session} do
    account = Fixtures.Accounts.create_account()
    provider = Fixtures.Auth.create_userpass_provider(account: account)
    provider_identifier = Fixtures.Auth.random_provider_identifier(provider)

    actor =
      Fixtures.Actors.create_actor(
        account: account,
        provider: provider,
        provider_identifier: provider_identifier
      )
      |> Fixtures.Actors.disable()

    password = "Firezone1234"

    identity =
      Fixtures.Auth.create_identity(
        account: account,
        provider: provider,
        actor: actor,
        provider_virtual_state: %{"password" => password, "password_confirmation" => password}
      )

    session
    |> password_login_flow(account, identity.provider_identifier, password)
    |> assert_error_flash("Invalid username or password.")
  end

  feature "renders error on if actor is deleted", %{session: session} do
    account = Fixtures.Accounts.create_account()
    provider = Fixtures.Auth.create_userpass_provider(account: account)
    provider_identifier = Fixtures.Auth.random_provider_identifier(provider)

    actor =
      Fixtures.Actors.create_actor(
        account: account,
        provider: provider,
        provider_identifier: provider_identifier
      )

    password = "Firezone1234"

    identity =
      Fixtures.Auth.create_identity(
        account: account,
        provider: provider,
        actor: actor,
        provider_virtual_state: %{"password" => password, "password_confirmation" => password}
      )

    Fixtures.Actors.delete(actor)

    session
    |> password_login_flow(account, identity.provider_identifier, password)
    |> assert_error_flash("Invalid username or password.")
  end

  feature "redirects to actors index after successful sign in as account_admin_user", %{
    session: session
  } do
    account = Fixtures.Accounts.create_account()
    provider = Fixtures.Auth.create_userpass_provider(account: account)
    password = "Firezone1234"

    identity =
      Fixtures.Auth.create_identity(
        account: account,
        provider: provider,
        actor: [type: :account_admin_user],
        provider_virtual_state: %{"password" => password, "password_confirmation" => password}
      )

    session
    |> password_login_flow(account, identity.provider_identifier, password)
    |> assert_el(Query.css("#user-menu-button"))
    |> assert_path(~p"/#{account.slug}/sites")
    |> Auth.assert_authenticated(identity)
  end

  feature "redirects back to sign_in page after successful sign in as account_user", %{
    session: session
  } do
    account = Fixtures.Accounts.create_account()
    actor = Fixtures.Actors.create_actor(type: :account_user, account: account)
    provider = Fixtures.Auth.create_userpass_provider(account: account)
    password = "Firezone1234"

    identity =
      Fixtures.Auth.create_identity(
        account: account,
        provider: provider,
        actor: actor,
        provider_virtual_state: %{"password" => password, "password_confirmation" => password}
      )

    session
    |> password_login_flow(account, identity.provider_identifier, password)
    |> assert_path(~p"/#{account}")
    |> assert_error_flash(
      "You must have the admin role in Firezone to sign in to the admin portal."
    )
  end

  feature "redirects to client deep link after successful sign in as account_admin_user", %{
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
    actor = Fixtures.Actors.create_actor(type: :account_user, account: account)
    provider = Fixtures.Auth.create_userpass_provider(account: account)
    password = "Firezone1234"

    identity =
      Fixtures.Auth.create_identity(
        account: account,
        provider: provider,
        actor: actor,
        provider_virtual_state: %{"password" => password, "password_confirmation" => password}
      )

    session
    |> password_login_flow(account, identity.provider_identifier, password, redirect_params)
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

  feature "allows to sign in using email link to the client even with active browser session", %{
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
    actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
    provider = Fixtures.Auth.create_userpass_provider(account: account)
    password = "Firezone1234"

    identity =
      Fixtures.Auth.create_identity(
        account: account,
        provider: provider,
        actor: actor,
        provider_virtual_state: %{"password" => password, "password_confirmation" => password}
      )

    # Sign In as an portal user
    session
    |> password_login_flow(account, identity.provider_identifier, password)
    |> assert_el(Query.css("#user-menu-button"))
    |> assert_path(~p"/#{account.slug}/sites")
    |> Auth.assert_authenticated(identity)

    # And then to a client
    session
    |> password_login_flow(account, identity.provider_identifier, password, redirect_params)
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

  defp password_login_flow(session, account, username, password, redirect_params \\ %{}) do
    session
    |> visit(~p"/#{account}?#{redirect_params}")
    |> assert_el(Query.text("#{account.name}"))
    |> assert_el(Query.text("Sign in with username and password"))
    |> fill_form(%{
      "userpass[provider_identifier]" => username,
      "userpass[secret]" => password
    })
    |> click(Query.button("Sign in"))
  end

  defp assert_error_flash(session, text) do
    assert_text(session, Query.css(".flash-error"), text)
    session
  end
end
