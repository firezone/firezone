defmodule Web.Live.Groups.IndexTest do
  use Web.ConnCase, async: true

  setup do
    account = Fixtures.Accounts.create_account()
    identity = Fixtures.Auth.create_identity(account: account, actor: [type: :account_admin_user])

    %{
      account: account,
      identity: identity
    }
  end

  test "redirects to sign in page for unauthorized user", %{account: account, conn: conn} do
    path = ~p"/#{account}/groups"

    assert live(conn, path) ==
             {:error,
              {:redirect,
               %{
                 to: ~p"/#{account}?#{%{redirect_to: path}}",
                 flash: %{"error" => "You must sign in to access this page."}
               }}}
  end

  test "renders breadcrumbs item", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    {:ok, _lv, html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/groups")

    assert item = html |> Floki.parse_fragment!() |> Floki.find("[aria-label='Breadcrumb']")
    breadcrumbs = String.trim(Floki.text(item))
    assert breadcrumbs =~ "Groups"
  end

  test "renders add group button", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    {:ok, _lv, html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/groups")

    assert button =
             html
             |> Floki.parse_fragment!()
             |> Floki.find("a[href='/#{account.slug}/groups/new']")

    assert Floki.text(button) =~ "Add Group"
  end

  test "filters form has onkeydown attribute to prevent Enter from submitting form", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    {:ok, _lv, html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/groups")

    assert form = html |> Floki.parse_fragment!() |> Floki.find("form#groups-filters")
    assert ["return event.key != 'Enter';"] = Floki.attribute(form, "onkeydown")
  end

  test "renders empty table when there are no groups", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    {:ok, _lv, html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/groups")

    assert html =~ "No groups to display"
    assert html =~ "Add Group"
    assert html =~ "go to settings"
    assert html =~ "to sync groups from an identity provider"
  end

  test "renders groups table", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    empty_group = Fixtures.Actors.create_group(account: account)

    group_with_few_preloads = Fixtures.Actors.create_group(account: account)
    actor = Fixtures.Actors.create_actor(account: account)

    Fixtures.Actors.create_membership(
      account: account,
      group: group_with_few_preloads,
      actor: actor
    )

    group_with_lots_of_preloads = Fixtures.Actors.create_group(account: account)

    actors =
      for _ <- 1..10 do
        actor = Fixtures.Actors.create_actor(account: account)

        Fixtures.Actors.create_membership(
          account: account,
          group: group_with_lots_of_preloads,
          actor: actor
        )

        actor
      end

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/groups")

    lv
    |> element("#groups")
    |> render()
    |> table_to_map()
    |> with_table_row("name", empty_group.name, fn row ->
      assert row["actors"] == "None"
      assert around_now?(row["created"])
    end)
    |> with_table_row("name", group_with_few_preloads.name, fn row ->
      assert row["actors"] == actor.name
      assert around_now?(row["created"])
    end)
    |> with_table_row("name", group_with_lots_of_preloads.name, fn row ->
      [peeked_names, tail] = String.split(row["actors"], " and ", trim: true)

      peeked_names = String.split(peeked_names, ",") |> Enum.map(&String.trim/1)
      all_names = Enum.map(actors, & &1.name)
      assert Enum.all?(peeked_names, &(&1 in all_names))

      assert tail =~ "7 more"

      assert around_now?(row["created"])
    end)
  end
end
