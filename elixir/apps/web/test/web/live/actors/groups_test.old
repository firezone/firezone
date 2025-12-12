defmodule Web.Live.Actors.GroupsTest do
  use Web.ConnCase, async: true

  setup do
    account = Fixtures.Accounts.create_account()
    actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
    identity = Fixtures.Auth.create_identity(account: account, actor: actor)

    %{
      account: account,
      actor: actor,
      identity: identity
    }
  end

  test "redirects to sign in page for unauthorized user", %{
    account: account,
    actor: actor,
    conn: conn
  } do
    path = ~p"/#{account}/actors/#{actor}/edit_groups"

    assert live(conn, path) ==
             {:error,
              {:redirect,
               %{
                 to: ~p"/#{account}?#{%{redirect_to: path}}",
                 flash: %{"error" => "You must sign in to access this page."}
               }}}
  end

  test "renders not found error when actor is deleted", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    actor =
      Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
      |> Fixtures.Actors.delete()

    assert_raise Web.LiveErrors.NotFoundError, fn ->
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/actors/#{actor}/edit_groups")
    end
  end

  test "renders breadcrumbs item", %{
    account: account,
    identity: identity,
    actor: actor,
    conn: conn
  } do
    {:ok, _lv, html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/actors/#{actor}/edit_groups")

    assert item = html |> Floki.parse_fragment!() |> Floki.find("[aria-label='Breadcrumb']")
    breadcrumbs = String.trim(Floki.text(item))
    assert breadcrumbs =~ "Actors"
    assert breadcrumbs =~ actor.name
    assert breadcrumbs =~ "Group Memberships"
  end

  test "renders table with all groups", %{
    account: account,
    actor: actor,
    identity: identity,
    conn: conn
  } do
    group1 = Fixtures.Actors.create_group(account: account)
    group2 = Fixtures.Actors.create_group(account: account)
    group3 = Fixtures.Actors.create_group(account: account)
    Fixtures.Actors.create_managed_group(account: account)

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/actors/#{actor}/edit_groups")

    lv
    |> element("#groups")
    |> render()
    |> table_to_map()
    |> tap(fn rows ->
      assert length(rows) == 3
    end)
    |> with_table_row("group", "#{group1.name}", fn row ->
      assert row["group"] == group1.name
      assert row[""] == "Add"
    end)
    |> with_table_row("group", "#{group2.name}", fn row ->
      assert row["group"] == group2.name
      assert row[""] == "Add"
    end)
    |> with_table_row("group", "#{group3.name}", fn row ->
      assert row["group"] == group3.name
      assert row[""] == "Add"
    end)
  end

  test "changes rows status on add/remove clicks", %{
    account: account,
    actor: actor,
    identity: identity,
    conn: conn
  } do
    group = Fixtures.Actors.create_group(account: account)

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/actors/#{actor}/edit_groups")

    lv
    |> tap(fn lv ->
      rows =
        lv
        |> element("#groups")
        |> render()
        |> table_to_map()

      assert [row] = rows
      assert row["group"] == "#{group.name}"
      assert row[""] == "Add"
    end)
    |> tap(fn lv ->
      [row] =
        lv
        |> element("tr button", "Add")
        |> render_click()
        |> Floki.parse_fragment!()
        |> Floki.find("#groups")
        |> table_to_map()

      assert row[""] == "Remove"
    end)
    |> tap(fn lv ->
      [row] =
        lv
        |> element("tr button", "Remove")
        |> render_click()
        |> Floki.parse_fragment!()
        |> Floki.find("#groups")
        |> table_to_map()

      assert row[""] == "Add"
    end)
  end

  test "changes actors on submit", %{
    account: account,
    actor: actor,
    identity: identity,
    conn: conn
  } do
    group1 = Fixtures.Actors.create_group(account: account)
    group2 = Fixtures.Actors.create_group(account: account)
    group3 = Fixtures.Actors.create_group(account: account)

    Fixtures.Actors.create_membership(group: group1, actor: actor)

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/actors/#{actor}/edit_groups")

    lv
    |> element("#group-#{group1.id} button", "Remove")
    |> render_click()

    lv
    |> element("#group-#{group2.id} button", "Add")
    |> render_click()

    lv
    |> element("#group-#{group3.id} button", "Add")
    |> render_click()

    lv
    |> element("button[type=submit]", "Save")
    |> render_click()

    assert_redirected(lv, ~p"/#{account}/actors/#{actor}")

    actor = Repo.preload(actor, :groups, force: true)

    group_ids = Enum.map(actor.groups, & &1.id)
    assert length(group_ids) == 2
    assert group1.id not in group_ids
    assert group2.id in group_ids
    assert group3.id in group_ids
  end
end
