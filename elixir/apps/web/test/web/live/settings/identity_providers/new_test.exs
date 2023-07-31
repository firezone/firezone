defmodule Web.Auth.SettingsLive.IdentityProviders.NewLiveTest do
  use Web.ConnCase, async: true
  alias Domain.{AccountsFixtures, ActorsFixtures, AuthFixtures}

  setup do
    Domain.Config.put_system_env_override(:outbound_email_adapter, Swoosh.Adapters.Postmark)

    account = AccountsFixtures.create_account()
    actor = ActorsFixtures.create_actor(type: :account_admin_user, account: account)

    {provider, bypass} =
      AuthFixtures.start_openid_providers(["google"])
      |> AuthFixtures.create_openid_connect_provider(account: account)

    identity = AuthFixtures.create_identity(account: account, actor: actor, provider: provider)

    %{
      account: account,
      actor: actor,
      openid_connect_provider: provider,
      bypass: bypass,
      identity: identity
    }
  end

  test "redirects to sign in page for unauthorized user", %{account: account, conn: conn} do
    assert live(conn, ~p"/#{account}/settings/identity_providers/new") ==
             {:error,
              {:redirect,
               %{
                 to: ~p"/#{account}/sign_in",
                 flash: %{"error" => "You must log in to access this page."}
               }}}
  end

  test "renders available options", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    {:ok, lv, html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/settings/identity_providers/new")

    assert has_element?(lv, "#idp-option-google_workspace")
    assert html =~ "Google Workspace"

    assert has_element?(lv, "#idp-option-openid_connect")
    assert html =~ "OpenID Connect"
  end
end
