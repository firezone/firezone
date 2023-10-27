defmodule Web.Live.Sites.NewTest do
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
    conn: conn
  } do
    assert live(conn, ~p"/#{account}/sites/new") ==
             {:error,
              {:redirect,
               %{
                 to: ~p"/#{account}",
                 flash: %{"error" => "You must log in to access this page."}
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
      |> live(~p"/#{account}/sites/new")

    assert item = Floki.find(html, "[aria-label='Breadcrumb']")
    breadcrumbs = String.trim(Floki.text(item))
    assert breadcrumbs =~ "Sites"
    assert breadcrumbs =~ "Add"
  end

  test "renders form", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/sites/new")

    form = form(lv, "form")

    assert find_inputs(form) == [
             "group[name_prefix]"
           ]
  end

  test "renders changeset errors on input change", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    attrs = Fixtures.Gateways.group_attrs() |> Map.take([:name_prefix])

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/sites/new")

    lv
    |> form("form", group: attrs)
    |> validate_change(%{group: %{name_prefix: String.duplicate("a", 256)}}, fn form, _html ->
      assert form_validation_errors(form) == %{
               "group[name_prefix]" => ["should be at most 64 character(s)"]
             }
    end)
  end

  test "renders changeset errors on submit", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    other_gateway = Fixtures.Gateways.create_group(account: account)
    attrs = %{name_prefix: other_gateway.name_prefix}

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/sites/new")

    assert lv
           |> form("form", group: attrs)
           |> render_submit()
           |> form_validation_errors() == %{
             "group[name_prefix]" => ["has already been taken"]
           }
  end

  test "creates a new group on valid attrs and redirects when gateway is connected", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    attrs = Fixtures.Gateways.group_attrs() |> Map.take([:name_prefix])

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/sites/new")

    html =
      lv
      |> form("form", group: attrs)
      |> render_submit()

    assert html =~ "Select deployment method"
    assert html =~ "FIREZONE_TOKEN="
    assert html =~ "docker run"
    assert html =~ "Waiting for gateway connection..."

    assert Regex.run(~r/FIREZONE_ID=([^ ]+)/, html) |> List.last()
    token = Regex.run(~r/FIREZONE_TOKEN=([^ ]+)/, html) |> List.last() |> String.trim("&quot;")
    assert {:ok, _token} = Domain.Gateways.authorize_gateway(token)

    group =
      Repo.get_by(Domain.Gateways.Group, name_prefix: attrs.name_prefix)
      |> Repo.preload(:tokens)

    gateway = Fixtures.Gateways.create_gateway(account: account, group: group)
    Domain.Gateways.connect_gateway(gateway)

    assert assert_redirect(lv, ~p"/#{account}/sites/#{group}")
  end
end
