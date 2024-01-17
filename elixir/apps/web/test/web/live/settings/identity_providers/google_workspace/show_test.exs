defmodule Web.Live.Settings.IdentityProviders.GoogleWorkspace.ShowTest do
  use Web.ConnCase, async: true

  setup do
    Domain.Config.put_env_override(:outbound_email_adapter_configured?, true)

    account = Fixtures.Accounts.create_account()
    actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
    identity = Fixtures.Auth.create_identity(account: account, actor: actor)

    {provider, bypass} =
      Fixtures.Auth.start_and_create_google_workspace_provider(account: account)

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
    path = ~p"/#{account}/settings/identity_providers/google_workspace/#{provider}"

    assert live(conn, path) ==
             {:error,
              {:redirect,
               %{
                 to: ~p"/#{account}?#{%{redirect_to: path}}",
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
      |> live(~p"/#{account}/settings/identity_providers/google_workspace/#{provider}")

    assert html =~ "(deleted)"
    assert active_buttons(html) == []
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
      |> live(~p"/#{account}/settings/identity_providers/google_workspace/#{provider}")

    assert item = Floki.find(html, "[aria-label='Breadcrumb']")
    breadcrumbs = String.trim(Floki.text(item))
    assert breadcrumbs =~ "Identity Providers Settings"
    assert breadcrumbs =~ provider.name
  end

  test "renders provider details", %{
    account: account,
    provider: provider,
    identity: identity,
    conn: conn
  } do
    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/settings/identity_providers/google_workspace/#{provider}")

    table =
      lv
      |> element("#provider")
      |> render()
      |> vertical_table_to_map()

    assert table["name"] == provider.name
    assert table["status"] == "Active"
    assert table["sync status"] == "Never synced"
    assert table["client id"] == provider.adapter_config["client_id"]
    assert around_now?(table["created"])
  end

  test "renders sync status", %{
    account: account,
    provider: provider,
    identity: identity,
    conn: conn
  } do
    provider = Fixtures.Auth.fail_provider_sync(provider)
    Fixtures.Auth.create_identity(account: account, provider: provider)

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/settings/identity_providers/google_workspace/#{provider}")

    table =
      lv
      |> element("#provider")
      |> render()
      |> vertical_table_to_map()

    assert table["sync status"] =~ provider.last_sync_error

    provider = Fixtures.Auth.finish_provider_sync(provider)

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/settings/identity_providers/google_workspace/#{provider}")

    table =
      lv
      |> element("#provider")
      |> render()
      |> vertical_table_to_map()

    assert table["sync status"] =~ "Synced 1 identity and 0 groups"
  end

  test "renders name of actor that created provider", %{
    account: account,
    actor: actor,
    provider: provider,
    identity: identity,
    conn: conn
  } do
    provider
    |> Ecto.Changeset.change(
      created_by: :identity,
      created_by_identity_id: identity.id
    )
    |> Repo.update!()

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/settings/identity_providers/google_workspace/#{provider}")

    assert lv
           |> element("#provider")
           |> render()
           |> vertical_table_to_map()
           |> Map.fetch!("created") =~ "by #{actor.name}"
  end

  test "renders provider status", %{
    account: account,
    provider: provider,
    identity: identity,
    conn: conn
  } do
    provider
    |> Ecto.Changeset.change(disabled_at: DateTime.utc_now())
    |> Repo.update!()

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/settings/identity_providers/google_workspace/#{provider}")

    assert lv
           |> element("#provider")
           |> render()
           |> vertical_table_to_map()
           |> Map.fetch!("status") == "Disabled"

    provider
    |> Ecto.Changeset.change(
      disabled_at: DateTime.utc_now(),
      adapter_state: %{"status" => "pending_access_token"}
    )
    |> Repo.update!()

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/settings/identity_providers/google_workspace/#{provider}")

    assert lv
           |> element("#provider")
           |> render()
           |> vertical_table_to_map()
           |> Map.fetch!("status") == "Provisioning Connect IdP"
  end

  test "disables status while pending for access token", %{
    account: account,
    provider: provider,
    identity: identity,
    conn: conn
  } do
    provider
    |> Ecto.Changeset.change(
      disabled_at: DateTime.utc_now(),
      adapter_state: %{"status" => "pending_access_token"}
    )
    |> Repo.update!()

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/settings/identity_providers/google_workspace/#{provider}")

    refute lv |> element("button", "Enable Identity Provider") |> has_element?()
    refute lv |> element("button", "Disable Identity Provider") |> has_element?()
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
      |> live(~p"/#{account}/settings/identity_providers/google_workspace/#{provider}")

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
      |> live(~p"/#{account}/settings/identity_providers/google_workspace/#{provider}")

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
      |> live(~p"/#{account}/settings/identity_providers/google_workspace/#{provider}")

    assert lv
           |> element("a", "Reconnect")
           |> render()
           |> Floki.attribute("href")
           |> hd() ==
             ~p"/#{account.id}/settings/identity_providers/google_workspace/#{provider}/redirect"
  end
end
