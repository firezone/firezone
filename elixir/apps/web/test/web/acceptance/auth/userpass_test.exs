defmodule Web.Acceptance.Auth.UserPassTest do
  use Web.AcceptanceCase, async: true
  alias Domain.{AccountsFixtures, AuthFixtures, ActorsFixtures}

  feature "renders error on invalid login or password", %{session: session} do
    account = AccountsFixtures.create_account()
    provider = AuthFixtures.create_userpass_provider(account: account)
    password = "Firezone1234"

    identity =
      AuthFixtures.create_identity(
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
    account = AccountsFixtures.create_account()
    provider = AuthFixtures.create_userpass_provider(account: account)
    password = "Firezone1234"

    identity =
      AuthFixtures.create_identity(
        account: account,
        provider: provider,
        provider_virtual_state: %{"password" => password, "password_confirmation" => password}
      )
      |> AuthFixtures.delete_identity()

    session
    |> password_login_flow(account, identity.provider_identifier, password)
    |> assert_error_flash("Invalid username or password.")
  end

  feature "renders error on if actor is disabled", %{session: session} do
    account = AccountsFixtures.create_account()
    provider = AuthFixtures.create_userpass_provider(account: account)
    provider_identifier = AuthFixtures.random_provider_identifier(provider)

    actor =
      ActorsFixtures.create_actor(
        account: account,
        provider: provider,
        provider_identifier: provider_identifier
      )
      |> ActorsFixtures.disable()

    password = "Firezone1234"

    identity =
      AuthFixtures.create_identity(
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
    account = AccountsFixtures.create_account()
    provider = AuthFixtures.create_userpass_provider(account: account)
    provider_identifier = AuthFixtures.random_provider_identifier(provider)

    actor =
      ActorsFixtures.create_actor(
        account: account,
        provider: provider,
        provider_identifier: provider_identifier
      )
      |> ActorsFixtures.delete()

    password = "Firezone1234"

    identity =
      AuthFixtures.create_identity(
        account: account,
        provider: provider,
        actor: actor,
        provider_virtual_state: %{"password" => password, "password_confirmation" => password}
      )

    session
    |> password_login_flow(account, identity.provider_identifier, password)
    |> assert_error_flash("Invalid username or password.")
  end

  feature "redirects to dashboard after successful log in as account_admin_user", %{
    session: session
  } do
    account = AccountsFixtures.create_account()
    provider = AuthFixtures.create_userpass_provider(account: account)
    password = "Firezone1234"

    identity =
      AuthFixtures.create_identity(
        account: account,
        provider: provider,
        actor_default_type: :account_admin_user,
        provider_virtual_state: %{"password" => password, "password_confirmation" => password}
      )

    session
    |> password_login_flow(account, identity.provider_identifier, password)
    |> assert_el(Query.css("#user-menu-button"))
    |> assert_path(~p"/#{account.slug}/dashboard")
    |> Auth.assert_authenticated(identity)
  end

  feature "redirects to landing page after successful log in as account_user", %{
    session: session
  } do
    account = AccountsFixtures.create_account()
    provider = AuthFixtures.create_userpass_provider(account: account)
    password = "Firezone1234"

    identity =
      AuthFixtures.create_identity(
        account: account,
        provider: provider,
        actor_default_type: :account_user,
        provider_virtual_state: %{"password" => password, "password_confirmation" => password}
      )

    session
    |> password_login_flow(account, identity.provider_identifier, password)
    |> assert_path(~p"/#{account}/")
  end

  defp password_login_flow(session, account, username, password) do
    session
    |> visit(~p"/#{account}/sign_in")
    |> assert_el(Query.text("Welcome back"))
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
