defmodule Web.Live.Settings.IdentityProviders.OpenIDConnect.ShowTest do
  use Web.ConnCase, async: true

  setup do
    Domain.Config.put_env_override(:outbound_email_adapter_configured?, true)

    account = Fixtures.Accounts.create_account()
    actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)

    {provider, bypass} = Fixtures.Auth.start_and_create_openid_connect_provider(account: account)

    identity = Fixtures.Auth.create_identity(account: account, actor: actor, provider: provider)

    %{
      account: account,
      actor: actor,
      provider: provider,
      identity: identity,
      bypass: bypass
    }
  end

  test "redirects to sign in page for unauthorized user", %{
    account: account,
    provider: provider,
    conn: conn
  } do
    assert live(conn, ~p"/#{account}/settings/identity_providers/openid_connect/#{provider}") ==
             {:error,
              {:redirect,
               %{
                 to: ~p"/#{account}",
                 flash: %{"error" => "You must log in to access this page."}
               }}}
  end

  test "renders deleted provider without action buttons", %{
    account: account,
    provider: provider,
    identity: identity,
    conn: conn
  } do
    provider = Fixtures.Auth.delete_provider(provider)

    {:ok, _lv, html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/settings/identity_providers/openid_connect/#{provider}")

    assert html =~ "(deleted)"
    refute html =~ "Danger Zone"
    refute html =~ "Edit"
    refute html =~ "Deploy"
  end

  test "renders breadcrumbs item", %{
    account: account,
    provider: provider,
    identity: identity,
    conn: conn
  } do
    {:ok, _lv, html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/settings/identity_providers/openid_connect/#{provider}")

    assert item = Floki.find(html, "[aria-label='Breadcrumb']")
    breadcrumbs = String.trim(Floki.text(item))
    assert breadcrumbs =~ "Identity Providers Settings"
    assert breadcrumbs =~ provider.name
  end

  test "renders provider details", %{
    account: account,
    actor: actor,
    provider: provider,
    identity: identity,
    conn: conn,
    bypass: bypass
  } do
    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/settings/identity_providers/openid_connect/#{provider}")

    table =
      lv
      |> element("#provider")
      |> render()
      |> vertical_table_to_map()

    assert table["name"] == provider.name
    assert table["status"] == "Active"
    assert table["type"] == "OpenID Connect"
    assert table["response type"] == "code"
    assert table["scope"] == provider.adapter_config["scope"]
    assert table["client id"] == provider.adapter_config["client_id"]

    assert table["discovery url"] ==
             "http://localhost:#{bypass.port}/.well-known/openid-configuration"

    assert around_now?(table["created"])

    provider
    |> Ecto.Changeset.change(
      created_by: :identity,
      created_by_identity_id: identity.id
    )
    |> Repo.update!()

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/settings/identity_providers/openid_connect/#{provider}")

    assert lv
           |> element("#provider")
           |> render()
           |> vertical_table_to_map()
           |> Map.fetch!("created") =~ "by #{actor.name}"
  end

  test "allows changing provider status", %{
    account: account,
    provider: provider,
    identity: identity,
    conn: conn
  } do
    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/settings/identity_providers/openid_connect/#{provider}")

    assert lv
           |> element("button", "Disable")
           |> render_click()
           |> Floki.find("#provider")
           |> vertical_table_to_map()
           |> Map.fetch!("status") == "Disabled"

    assert lv
           |> element("button", "Enable")
           |> render_click()
           |> Floki.find("#provider")
           |> vertical_table_to_map()
           |> Map.fetch!("status") == "Active"
  end

  test "allows deleting identity providers", %{
    account: account,
    provider: provider,
    identity: identity,
    conn: conn
  } do
    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/settings/identity_providers/openid_connect/#{provider}")

    lv
    |> element("button", "Delete Identity Provider")
    |> render_click()

    assert_redirected(lv, ~p"/#{account}/settings/identity_providers")

    assert Repo.get(Domain.Auth.Provider, provider.id).deleted_at
  end

  test "allows reconnecting identity providers", %{
    account: account,
    provider: provider,
    identity: identity,
    conn: conn
  } do
    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/settings/identity_providers/openid_connect/#{provider}")

    assert lv
           |> element("a", "Reconnect")
           |> render()
           |> Floki.attribute("href")
           |> hd() ==
             ~p"/#{account.id}/settings/identity_providers/openid_connect/#{provider}/redirect"
  end
end
