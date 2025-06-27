defmodule Web.Acceptance.AuthTest do
  use Web.AcceptanceCase, async: true

  feature "renders all sign in options", %{session: session} do
    account = Fixtures.Accounts.create_account()

    Domain.Config.put_env_override(:outbound_email_adapter_configured?, true)

    Fixtures.Auth.create_userpass_provider(account: account)
    Fixtures.Auth.create_email_provider(account: account)

    {openid_connect_provider, _bypass} =
      Fixtures.Auth.start_and_create_openid_connect_provider(account: account)

    session
    |> visit(~p"/#{account}")
    |> assert_el(Query.text("#{account.name}"))
    |> assert_el(Query.link("Sign in with #{openid_connect_provider.name}"))
    |> assert_el(Query.text("Sign in with username and password"))
    |> assert_el(Query.text("Sign in with email"))
  end

  describe "sign out" do
    feature "signs out admin user", %{session: session} do
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
      |> visit(~p"/#{account}")
      |> Auth.authenticate(identity)
      |> visit(~p"/#{account}/actors")
      |> assert_el(Query.css("#user-menu-button"))
      |> click(Query.css("#user-menu-button"))
      |> assert_el(Query.link("Sign out", visible: true))
      |> click(Query.link("Sign out"))
      |> assert_el(Query.text("Sign in with username and password"))
      |> Auth.assert_unauthenticated()
      |> assert_path(~p"/#{account}")
    end

    feature "signs out unprivileged user", %{session: session} do
      account = Fixtures.Accounts.create_account()
      provider = Fixtures.Auth.create_userpass_provider(account: account)
      password = "Firezone1234"

      identity =
        Fixtures.Auth.create_identity(
          account: account,
          provider: provider,
          actor: [type: :account_user],
          provider_virtual_state: %{"password" => password, "password_confirmation" => password}
        )

      session
      |> visit(~p"/#{account}")
      |> Auth.authenticate(identity)
      |> visit(~p"/#{account}/sign_out")
      |> assert_el(Query.text("Sign in with username and password"))
      |> Auth.assert_unauthenticated()
      |> assert_path(~p"/#{account}")
    end
  end

  feature "signs out browser session if token is revoked", %{session: session} do
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
    |> visit(~p"/#{account}")
    |> Auth.authenticate(identity)
    |> visit(~p"/#{account}/actors")

    {:ok, tokens} = Domain.Tokens.delete_tokens_for(identity)

    for token <- tokens do
      assert %DateTime{} = token.deleted_at
      Domain.Events.Hooks.Tokens.on_delete(%{"id" => token.id})
    end

    wait_for(
      fn ->
        assert_el(session, Query.text("You must sign in to access this page."))
      end,
      10_000
    )

    assert_path(session, ~p"/#{account}")
  end

  feature "does not allow regular user to navigate to admin routes", %{session: session} do
    account = Fixtures.Accounts.create_account()
    provider = Fixtures.Auth.create_userpass_provider(account: account)
    password = "Firezone1234"

    identity =
      Fixtures.Auth.create_identity(
        account: account,
        provider: provider,
        actor: [type: :account_user],
        provider_virtual_state: %{"password" => password, "password_confirmation" => password}
      )

    session =
      session
      |> visit(~p"/#{account}")
      |> Auth.authenticate(identity)
      |> visit(~p"/#{account}/actors")

    assert text(session) =~ "Sorry, we couldn't find this page"

    assert_path(session, ~p"/#{account}/actors")
  end
end
