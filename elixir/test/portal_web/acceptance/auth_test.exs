defmodule PortalWeb.Acceptance.AuthTest do
  use PortalWeb.AcceptanceCase, async: true

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.AuthProviderFixtures

  alias PortalWeb.AcceptanceCase.Auth
  alias PortalWeb.Mocks

  feature "renders all sign in options", %{session: session} do
    Portal.Config.put_env_override(:outbound_email_adapter_configured?, true)

    account = account_fixture()
    _email_provider = email_otp_provider_fixture(account: account)
    _userpass_provider = userpass_provider_fixture(account: account)

    Mocks.OIDC.stub_discovery_document()
    oidc_provider = oidc_provider_fixture(:mock, account: account)

    session
    |> visit(~p"/#{account}")
    |> assert_el(Query.text("#{account.name}"))
    |> assert_el(Query.link("Sign in with #{oidc_provider.name}"))
    |> assert_el(Query.text("Sign in with username and password"))
    |> assert_el(Query.text("Sign in with email"))
  end

  describe "sign out" do
    feature "signs out admin user", %{session: session} do
      account = account_fixture()
      auth_provider = auth_provider_fixture(type: :userpass, account: account)
      _userpass = userpass_provider_fixture(auth_provider: auth_provider, account: account)
      actor = actor_fixture(account: account, type: :account_admin_user)

      session
      |> visit(~p"/#{account}")
      |> Auth.authenticate(actor, auth_provider)
      |> visit(~p"/#{account}/actors")
      |> assert_el(Query.css("#user-menu-button", visible: true))
      |> click(Query.css("#user-menu-button"))
      |> assert_el(Query.link("Sign out", visible: true))
      |> click(Query.link("Sign out"))
      |> assert_el(Query.text("Sign in with username and password"))
      |> Auth.assert_unauthenticated(account.id)
      |> assert_path(~p"/#{account}")
    end

    feature "signs out unprivileged user", %{session: session} do
      account = account_fixture()
      auth_provider = auth_provider_fixture(type: :userpass, account: account)
      _userpass = userpass_provider_fixture(auth_provider: auth_provider, account: account)
      actor = actor_fixture(account: account, type: :account_user)

      session
      |> visit(~p"/#{account}")
      |> Auth.authenticate(actor, auth_provider)
      |> visit(~p"/#{account}/sign_out")
      |> assert_el(Query.text("Sign in with username and password"))
      |> Auth.assert_unauthenticated(account.id)
      |> assert_path(~p"/#{account}")
    end
  end

  feature "does not allow regular user to navigate to admin routes", %{session: session} do
    account = account_fixture()
    auth_provider = auth_provider_fixture(type: :userpass, account: account)
    _userpass = userpass_provider_fixture(auth_provider: auth_provider, account: account)
    actor = actor_fixture(account: account, type: :account_user)

    session =
      session
      |> visit(~p"/#{account}")
      |> Auth.authenticate(actor, auth_provider)
      |> visit(~p"/#{account}/actors")

    assert text(session) =~ "Sorry, we couldn't find this page"
    assert_path(session, ~p"/#{account}/actors")
  end
end
