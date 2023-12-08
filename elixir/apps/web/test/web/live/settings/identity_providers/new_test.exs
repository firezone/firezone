defmodule Web.Live.Settings.IdentityProviders.NewTest do
  use Web.ConnCase, async: true

  setup do
    Domain.Config.put_env_override(:outbound_email_adapter_configured?, true)

    account = Fixtures.Accounts.create_account()
    actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)

    {provider, bypass} =
      Fixtures.Auth.start_and_create_openid_connect_provider(account: account)

    identity = Fixtures.Auth.create_identity(account: account, actor: actor, provider: provider)

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
                 to: ~p"/#{account}",
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
    assert html =~ "Feature available on the Enterprise plan"
    assert html =~ "ENTERPRISE"

    assert has_element?(lv, "#idp-option-openid_connect")
    assert html =~ "OpenID Connect"
  end
end
