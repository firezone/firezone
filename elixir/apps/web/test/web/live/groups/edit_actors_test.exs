defmodule Web.Live.Groups.EditActorsTest do
  use Web.ConnCase, async: true

  setup do
    account = Fixtures.Accounts.create_account()
    actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
    identity = Fixtures.Auth.create_identity(account: account, actor: actor)
    group = Fixtures.Actors.create_group(account: account, subject: [actor: actor])

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
    path = ~p"/#{account}/groups/#{group}/edit_actors"

    assert live(conn, path) ==
             {:error,
              {:redirect,
               %{
                 to: ~p"/#{account}?#{%{redirect_to: path}}",
                 flash: %{"error" => "You must sign in to access this page."}
               }}}
  end

  test "renders not found error when group is deleted", %{
    account: account,
    identity: identity,
    group: group,
    conn: conn
  } do
    group = Fixtures.Actors.delete_group(group)

    assert_raise Web.LiveErrors.NotFoundError, fn ->
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/groups/#{group}/edit_actors")
    end
  end

  test "renders not found error when group is synced", %{
    account: account,
    identity: identity,
    group: group,
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

    assert_raise Web.LiveErrors.NotFoundError, fn ->
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/groups/#{group}/edit")
    end
  end

  test "renders breadcrumbs item", %{
    account: account,
    identity: identity,
    group: group,
    conn: conn
  } do
    {:ok, _lv, html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/groups/#{group}/edit_actors")

    assert item = html |> Floki.parse_fragment!() |> Floki.find("[aria-label='Breadcrumb']")
    breadcrumbs = String.trim(Floki.text(item))
    assert breadcrumbs =~ "Groups"
    assert breadcrumbs =~ group.name
    assert breadcrumbs =~ "Edit Actors"
  end

  test "renders table with all actors", %{
    account: account,
    actor: admin_actor,
    identity: identity,
    group: group,
    conn: conn
  } do
    admin_actor = Repo.preload(admin_actor, identities: [:provider])
    user_actor = Fixtures.Actors.create_actor(type: :account_user, account: account)
    service_account = Fixtures.Actors.create_actor(type: :service_account, account: account)

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/groups/#{group}/edit_actors")

    lv
    |> element("#actors")
    |> render()
    |> table_to_map()
    |> tap(fn rows ->
      assert length(rows) == 3
    end)
    |> with_table_row("actor", "#{admin_actor.name} (admin)", fn row ->
      for(identity <- admin_actor.identities) do
        assert row["identities"] =~ identity.provider_identifier
      end

      assert row[""] == "Add"
    end)
    |> with_table_row("actor", user_actor.name, fn row ->
      assert row["identities"] == ""
      assert row[""] == "Add"
    end)
    |> with_table_row("actor", "#{service_account.name} (service account)", fn row ->
      assert row["identities"] == ""
      assert row[""] == "Add"
    end)
  end

  test "changes rows status on add/remove clicks", %{
    account: account,
    actor: actor,
    identity: identity,
    group: group,
    conn: conn
  } do
    actor = Repo.preload(actor, identities: [:provider])

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/groups/#{group}/edit_actors")

    lv
    |> tap(fn lv ->
      rows =
        lv
        |> element("#actors")
        |> render()
        |> table_to_map()

      assert [row] = rows

      assert row["actor"] == "#{actor.name} (admin)"

      for identity <- actor.identities do
        assert row["identities"] =~ identity.provider_identifier
      end

      assert row[""] == "Add"
    end)
    |> tap(fn lv ->
      [row] =
        lv
        |> element("tr button", "Add")
        |> render_click()
        |> Floki.parse_fragment!()
        |> Floki.find("#actors")
        |> table_to_map()

      assert row[""] == "Remove"
    end)
    |> tap(fn lv ->
      [row] =
        lv
        |> element("tr button", "Remove")
        |> render_click()
        |> Floki.parse_fragment!()
        |> Floki.find("#actors")
        |> table_to_map()

      assert row[""] == "Add"
    end)
  end

  test "changes actors on submit", %{
    account: account,
    actor: admin_actor,
    identity: identity,
    group: group,
    conn: conn
  } do
    admin_actor = Repo.preload(admin_actor, identities: [:provider])
    user_actor = Fixtures.Actors.create_actor(type: :account_user, account: account)
    service_account = Fixtures.Actors.create_actor(type: :service_account, account: account)
    Fixtures.Actors.create_membership(group: group, actor: admin_actor)

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/groups/#{group}/edit_actors")

    lv
    |> element("#actor-#{admin_actor.id} button", "Remove")
    |> render_click()

    lv
    |> element("#actor-#{user_actor.id} button", "Add")
    |> render_click()

    lv
    |> element("#actor-#{service_account.id} button", "Add")
    |> render_click()

    lv
    |> element("button[type=submit]", "Confirm")
    |> render_click()

    assert_redirected(lv, ~p"/#{account}/groups/#{group}")

    group = Repo.preload(group, :actors, force: true)
    group_actor_ids = Enum.map(group.actors, & &1.id)
    assert length(group_actor_ids) == 2
    assert admin_actor.id not in group_actor_ids
    assert user_actor.id in group_actor_ids
    assert service_account.id in group_actor_ids
  end
end
