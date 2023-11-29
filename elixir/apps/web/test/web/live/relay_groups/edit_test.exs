defmodule Web.Live.RelayGroups.EditTest do
  use Web.ConnCase, async: true

  setup do
    account = Fixtures.Accounts.create_account()
    actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
    identity = Fixtures.Auth.create_identity(account: account, actor: actor)

    group = Fixtures.Relays.create_group(account: account)

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
    assert live(conn, ~p"/#{account}/relay_groups/#{group}/edit") ==
             {:error,
              {:redirect,
               %{
                 to: ~p"/#{account}",
                 flash: %{"error" => "You must log in to access this page."}
               }}}
  end

  test "renders not found error when relay is deleted", %{
    account: account,
    identity: identity,
    group: group,
    conn: conn
  } do
    group = Fixtures.Relays.delete_group(group)

    assert_raise Web.LiveErrors.NotFoundError, fn ->
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/relay_groups/#{group}/edit")
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
      |> live(~p"/#{account}/relay_groups/#{group}/edit")

    assert item = Floki.find(html, "[aria-label='Breadcrumb']")
    breadcrumbs = String.trim(Floki.text(item))
    assert breadcrumbs =~ "Relay Instance Groups"
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
      |> live(~p"/#{account}/relay_groups/#{group}/edit")

    form = form(lv, "form")

    assert find_inputs(form) == [
             "group[name]"
           ]
  end

  test "renders changeset errors on input change", %{
    account: account,
    identity: identity,
    group: group,
    conn: conn
  } do
    attrs = Fixtures.Relays.group_attrs() |> Map.take([:name])

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/relay_groups/#{group}/edit")

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
    other_group = Fixtures.Relays.create_group(account: account)
    attrs = %{name: other_group.name}

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/relay_groups/#{group}/edit")

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
    attrs = Fixtures.Relays.group_attrs() |> Map.take([:name])

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/relay_groups/#{group}/edit")

    lv
    |> form("form", group: attrs)
    |> render_submit()

    assert_redirected(lv, ~p"/#{account}/relay_groups/#{group}")

    assert group = Repo.get_by(Domain.Relays.Group, id: group.id)
    assert group.name == attrs.name
  end

  test "renders not found error when self_hosted_relays feature flag is false", %{
    account: account,
    identity: identity,
    group: group,
    conn: conn
  } do
    Domain.Config.feature_flag_override(:self_hosted_relays, false)

    assert_raise Web.LiveErrors.NotFoundError, fn ->
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/relay_groups/#{group}/edit")
    end
  end
end
