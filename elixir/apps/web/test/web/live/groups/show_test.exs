defmodule Web.Live.Groups.ShowTest do
  use Web.ConnCase, async: true

  setup do
    account = Fixtures.Accounts.create_account()
    actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
    identity = Fixtures.Auth.create_identity(account: account, actor: actor)
    subject = Fixtures.Auth.create_subject(account: account, actor: actor, identity: identity)
    group = Fixtures.Actors.create_group(account: account, subject: subject)

    %{
      account: account,
      actor: actor,
      identity: identity,
      group: group
    }
  end

  test "redirects to sign in page for unauthorized user", %{
    account: account,
    group: group,
    conn: conn
  } do
    path = ~p"/#{account}/groups/#{group}"

    assert live(conn, path) ==
             {:error,
              {:redirect,
               %{
                 to: ~p"/#{account}?#{%{redirect_to: path}}",
                 flash: %{"error" => "You must sign in to access this page."}
               }}}
  end

  test "renders deleted group without action buttons", %{
    account: account,
    group: group,
    identity: identity,
    conn: conn
  } do
    group = Fixtures.Actors.delete_group(group)

    {:ok, _lv, html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/groups/#{group}")

    assert html =~ "(deleted)"
    assert active_buttons(html) == []
  end

  test "renders breadcrumbs item", %{
    account: account,
    group: group,
    identity: identity,
    conn: conn
  } do
    {:ok, _lv, html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/groups/#{group}")

    assert item = Floki.find(html, "[aria-label='Breadcrumb']")
    breadcrumbs = String.trim(Floki.text(item))
    assert breadcrumbs =~ "Groups"
    assert breadcrumbs =~ group.name
  end

  test "renders group details", %{
    account: account,
    group: group,
    actor: actor,
    identity: identity,
    conn: conn
  } do
    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/groups/#{group}")

    table =
      lv
      |> element("#group")
      |> render()
      |> vertical_table_to_map()

    assert table["name"] == group.name
    assert around_now?(table["created"])
    assert table["created"] =~ "by #{actor.name}"
  end

  test "renders group details when created by API", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    actor = Fixtures.Actors.create_actor(type: :api_client, account: account)
    subject = Fixtures.Auth.create_subject(account: account, actor: actor)
    group = Fixtures.Actors.create_group(account: account, subject: subject)

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/groups/#{group}")

    table =
      lv
      |> element("#group")
      |> render()
      |> vertical_table_to_map()

    assert table["name"] == group.name
    assert around_now?(table["created"])
    assert table["created"] =~ "by #{actor.name}"
  end

  test "renders name of actor that created group", %{
    account: account,
    actor: actor,
    group: group,
    identity: identity,
    conn: conn
  } do
    group
    |> Ecto.Changeset.change(
      created_by: :identity,
      created_by_subject: %{"email" => identity.email, "name" => actor.name}
    )
    |> Repo.update!()

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/groups/#{group}")

    assert lv
           |> element("#group")
           |> render()
           |> vertical_table_to_map()
           |> Map.fetch!("created") =~ "by #{actor.name}"
  end

  test "renders provider that synced group", %{
    account: account,
    group: group,
    identity: identity,
    conn: conn
  } do
    {provider, _bypass} =
      Fixtures.Auth.start_and_create_google_workspace_provider(account: account)

    group
    |> Ecto.Changeset.change(
      created_by: :provider,
      provider_id: provider.id,
      provider_identifier: Ecto.UUID.generate()
    )
    |> Repo.update!()

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/groups/#{group}")

    assert lv
           |> element("#group")
           |> render()
           |> vertical_table_to_map()
           |> Map.fetch!("created") =~ "by Directory Sync"
  end

  test "renders group actors", %{
    account: account,
    group: group,
    identity: identity,
    conn: conn
  } do
    user_actor = Fixtures.Actors.create_actor(type: :account_user, account: account)
    Fixtures.Actors.create_membership(group: group, actor: user_actor)

    service_account = Fixtures.Actors.create_actor(type: :service_account, account: account)
    Fixtures.Actors.create_membership(group: group, actor: service_account)

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/groups/#{group}")

    lv
    |> element("#actors")
    |> render()
    |> table_to_map()
    |> with_table_row("name", user_actor.name, fn row ->
      user_actor = Repo.preload(user_actor, identities: [:provider])

      for identity <- user_actor.identities do
        assert row["identities"] =~ identity.provider.name
        assert row["identities"] =~ identity.provider_identifier
      end
    end)
    |> with_table_row("name", "#{service_account.name} (service account)", fn row ->
      service_account = Repo.preload(service_account, identities: [:provider])

      for identity <- service_account.identities do
        assert row["identities"] =~ identity.provider.name
        assert row["identities"] =~ identity.provider_identifier
      end
    end)
  end

  test "allows editing groups", %{
    account: account,
    group: group,
    identity: identity,
    conn: conn
  } do
    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/groups/#{group}")

    assert lv
           |> element("a:first-child", "Edit Group")
           |> render_click() ==
             {:error, {:live_redirect, %{to: ~p"/#{account}/groups/#{group}/edit", kind: :push}}}
  end

  test "does not allow editing or deleting synced groups", %{
    account: account,
    group: group,
    identity: identity,
    conn: conn
  } do
    {provider, _bypass} =
      Fixtures.Auth.start_and_create_google_workspace_provider(account: account)

    group
    |> Ecto.Changeset.change(
      created_by: :provider,
      provider_id: provider.id,
      provider_identifier: Ecto.UUID.generate()
    )
    |> Repo.update!()

    {:ok, lv, html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/groups/#{group}")

    refute has_element?(lv, "a", "Edit Group")
    refute has_element?(lv, "a", "Delete Group")
    refute html =~ "Danger Zone"
  end

  test "shows edit button when actors table is empty", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    group = Fixtures.Actors.create_group(account: account)

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/groups/#{group}")

    assert lv
           |> element("#actors-empty a", "Edit Actors")
           |> render_click() ==
             {:error,
              {:live_redirect, %{to: ~p"/#{account}/groups/#{group}/edit_actors", kind: :push}}}
  end

  test "does not allow editing synced actors", %{
    account: account,
    group: group,
    identity: identity,
    conn: conn
  } do
    {provider, _bypass} =
      Fixtures.Auth.start_and_create_google_workspace_provider(account: account)

    group
    |> Ecto.Changeset.change(
      created_by: :provider,
      provider_id: provider.id,
      provider_identifier: Ecto.UUID.generate()
    )
    |> Repo.update!()

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/groups/#{group}")

    refute has_element?(lv, "a", "Edit Actors")
  end

  test "allows deleting groups", %{
    account: account,
    group: group,
    identity: identity,
    conn: conn
  } do
    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/groups/#{group}")

    lv
    |> element("button[type=submit]", "Delete Group")
    |> render_click()

    assert_redirected(lv, ~p"/#{account}/groups")

    assert Repo.get(Domain.Actors.Group, group.id).deleted_at
  end
end
