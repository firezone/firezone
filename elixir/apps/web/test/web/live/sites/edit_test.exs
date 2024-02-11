defmodule Web.Live.Sites.EditTest do
  use Web.ConnCase, async: true

  setup do
    account = Fixtures.Accounts.create_account()
    actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
    identity = Fixtures.Auth.create_identity(account: account, actor: actor)

    group = Fixtures.Gateways.create_group(account: account)

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
    path = ~p"/#{account}/sites/#{group}/edit"

    assert live(conn, path) ==
             {:error,
              {:redirect,
               %{
                 to: ~p"/#{account}?#{%{redirect_to: path}}",
                 flash: %{"error" => "You must sign in to access this page."}
               }}}
  end

  test "renders not found error when gateway is deleted", %{
    account: account,
    identity: identity,
    group: group,
    conn: conn
  } do
    group = Fixtures.Gateways.delete_group(group)

    assert_raise Web.LiveErrors.NotFoundError, fn ->
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/sites/#{group}/edit")
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
      |> live(~p"/#{account}/sites/#{group}/edit")

    assert item = Floki.find(html, "[aria-label='Breadcrumb']")
    breadcrumbs = String.trim(Floki.text(item))
    assert breadcrumbs =~ "Sites"
    assert breadcrumbs =~ group.name
    assert breadcrumbs =~ "Edit"
  end

  test "renders form", %{
    account: account,
    identity: identity,
    group: group,
    conn: conn
  } do
    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/sites/#{group}/edit")

    form = form(lv, "form")

    assert find_inputs(form) == [
             "group[name]",
             "group[routing]"
           ]
  end

  test "renders changeset errors on input change", %{
    account: account,
    identity: identity,
    group: group,
    conn: conn
  } do
    attrs = Fixtures.Gateways.group_attrs() |> Map.take([:name])

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/sites/#{group}/edit")

    lv
    |> form("form", group: attrs)
    |> validate_change(%{group: %{name: String.duplicate("a", 256)}}, fn form, _html ->
      assert form_validation_errors(form) == %{
               "group[name]" => ["should be at most 64 character(s)"]
             }
    end)
    |> validate_change(%{group: %{name: ""}}, fn form, _html ->
      assert form_validation_errors(form) == %{
               "group[name]" => ["can't be blank"]
             }
    end)
  end

  test "renders changeset errors on submit", %{
    account: account,
    identity: identity,
    group: group,
    conn: conn
  } do
    other_group = Fixtures.Gateways.create_group(account: account)
    attrs = %{name: other_group.name}

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/sites/#{group}/edit")

    assert lv
           |> form("form", group: attrs)
           |> render_submit()
           |> form_validation_errors() == %{
             "group[name]" => ["has already been taken"]
           }
  end

  test "updates a group on valid attrs", %{
    account: account,
    identity: identity,
    group: group,
    conn: conn
  } do
    attrs = Fixtures.Gateways.group_attrs() |> Map.take([:name])

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/sites/#{group}/edit")

    lv
    |> form("form", group: attrs)
    |> render_submit()

    assert_redirected(lv, ~p"/#{account}/sites/#{group}")

    assert group = Repo.get_by(Domain.Gateways.Group, id: group.id)
    assert group.name == attrs.name
  end
end
