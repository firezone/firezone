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
      |> Fixtures.Actors.delete()

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

  feature "redirects to actors index after successful log in as account_admin_user", %{
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

  feature "redirects back to sign_in page after successful log in as account_user", %{
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
    |> assert_error_flash("Please use a client application to access Firezone.")
  end

  defp password_login_flow(session, account, username, password) do
    session
    |> visit(~p"/#{account}")
    |> assert_el(Query.text("Sign into #{account.name}"))
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
