defmodule Web.Acceptance.AuthTest do
  use Web.AcceptanceCase, async: true
  alias Domain.{AccountsFixtures, AuthFixtures}

  feature "renders all sign in options", %{session: session} do
    account = AccountsFixtures.create_account()
    AuthFixtures.create_userpass_provider(account: account)

    AuthFixtures.create_email_provider(account: account)

    AuthFixtures.create_token_provider(account: account)

    {openid_connect_provider, _bypass} =
      AuthFixtures.start_openid_providers(["google"])
      |> AuthFixtures.create_openid_connect_provider(account: account)

    session
    |> visit(~p"/#{account}/sign_in")
    |> assert_el(Query.text("Welcome back"))
    |> assert_el(Query.link("Log in with #{openid_connect_provider.name}"))
    |> assert_el(Query.text("Sign in with username and password"))
    |> assert_el(Query.text("Sign in with a magic link"))
  end

  describe "sign out" do
    feature "signs out admin user", %{session: session} do
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
      |> visit(~p"/#{account}")
      |> Auth.authenticate(identity)
      |> visit(~p"/#{account}/dashboard")
      |> assert_el(Query.css("#user-menu-button"))
      |> click(Query.css("#user-menu-button"))
      |> click(Query.link("Sign out"))
      |> assert_el(Query.text("Sign in with username and password"))
      |> Auth.assert_unauthenticated()
      |> assert_path(~p"/#{account}/sign_in")
    end

    feature "signs out unprivileged user", %{session: session} do
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
      |> visit(~p"/#{account}")
      |> Auth.authenticate(identity)
      |> visit(~p"/#{account}/sign_out")
      |> assert_el(Query.text("Sign in with username and password"))
      |> Auth.assert_unauthenticated()
      |> assert_path(~p"/#{account}/sign_in")
    end
  end

  feature "does not allow regular user to navigate to admin routes", %{session: session} do
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
    |> visit(~p"/#{account}")
    |> Auth.authenticate(identity)
    |> visit(~p"/#{account}/dashboard")
    |> assert_path(~p"/#{account}/")
  end
end
