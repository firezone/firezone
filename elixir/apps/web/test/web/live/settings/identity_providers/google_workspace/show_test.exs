defmodule Web.Auth.Settings.IdentityProviders.GoogleWorkspace.ShowTest do
  use Web.ConnCase, async: true

  setup do
    Domain.Config.put_system_env_override(:outbound_email_adapter, Swoosh.Adapters.Postmark)

    account = Fixtures.Accounts.create_account()
    actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)

    {provider, bypass} =
      Fixtures.Auth.start_and_create_google_workspace_provider(account: account)

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
    assert live(conn, ~p"/#{account}/settings/identity_providers/google_workspace/#{provider}") ==
             {:error,
              {:redirect,
               %{
                 to: ~p"/#{account}/sign_in",
                 flash: %{"error" => "You must log in to access this page."}
               }}}
  end

  test "renders not found error when provider is deleted", %{
    account: account,
    provider: provider,
    identity: identity,
    conn: conn
  } do
    provider = Fixtures.Auth.delete_provider(provider)

    assert_raise Web.LiveErrors.NotFoundError, fn ->
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/settings/identity_providers/google_workspace/#{provider}")
    end
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
    inserted_at = Cldr.DateTime.to_string!(provider.inserted_at, Web.CLDR, format: :short)

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/settings/identity_providers/google_workspace/#{provider}")

    assert lv
           |> element("#provider")
           |> render()
           |> vertical_table_to_map() == %{
             "name" => provider.name,
             "status" => "Active",
             "client id" => provider.adapter_config["client_id"],
             "created" => "#{inserted_at} by System"
           }
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
           |> Map.fetch!("status") == "Pending access token, reconnect identity provider"
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
           |> element("button", "Disable Identity Provider")
           |> render_click()
           |> Floki.find("#provider")
           |> vertical_table_to_map()
           |> Map.fetch!("status") == "Disabled"

    assert lv
           |> element("button", "Enable Identity Provider")
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

    assert lv
           |> element("button", "Delete Identity Provider")
           |> render_click() ==
             {:error, {:redirect, %{to: ~p"/#{account}/settings/identity_providers"}}}

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
           |> element("button", "Reconnect Identity Provider")
           |> render()
           |> Floki.attribute("navigate")
           |> hd() ==
             ~p"/#{account}/settings/identity_providers/google_workspace/#{provider}/redirect"
  end
end
