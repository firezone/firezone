defmodule Web.Live.Policies.NewTest do
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
    assert live(conn, ~p"/#{account}/policies/new") ==
             {:error,
              {:redirect,
               %{
                 to: ~p"/#{account}/sign_in",
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
      |> live(~p"/#{account}/policies/new")

    assert item = Floki.find(html, "[aria-label='Breadcrumb']")
    breadcrumbs = String.trim(Floki.text(item))
    assert breadcrumbs =~ "Policies"
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
      |> live(~p"/#{account}/policies/new")

    form = form(lv, "form")

    assert find_inputs(form) == [
             "policy[actor_group_id]",
             "policy[name]",
             "policy[resource_id]"
           ]
  end

  test "renders changeset errors on input change", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    group = Fixtures.Actors.create_group(account: account)
    resource = Fixtures.Resources.create_resource(account: account)

    attrs =
      Fixtures.Policies.policy_attrs()
      |> Map.take([:name])
      |> Map.put(:actor_group_id, group.id)
      |> Map.put(:resource_id, resource.id)

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/policies/new")

    lv
    |> form("form", policy: attrs)
    |> validate_change(%{policy: %{name: String.duplicate("a", 256)}}, fn form, _html ->
      assert form_validation_errors(form) == %{
               "policy[name]" => ["should be at most 255 character(s)"]
             }
    end)
    |> validate_change(%{policy: %{name: ""}}, fn form, _html ->
      assert form_validation_errors(form) == %{
               "policy[name]" => ["can't be blank"]
             }
    end)
  end

  test "renders changeset errors on submit", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    other_policy = Fixtures.Policies.create_policy(account: account)
    attrs = %{name: other_policy.name}

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/policies/new")

    assert lv
           |> form("form", policy: attrs)
           |> render_submit()
           |> form_validation_errors() == %{
             "policy[name]" => ["Policy Name already exists"]
           }

    attrs = %{
      name: "unique",
      actor_group_id: other_policy.actor_group_id,
      resource_id: other_policy.resource_id
    }

    assert lv
           |> form("form", policy: attrs)
           |> render_submit()
           |> form_validation_errors() == %{
             "policy[base]" => ["Policy with Group and Resource already exists"]
           }
  end

  test "creates a new policy on valid attrs and redirects", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    group = Fixtures.Actors.create_group(account: account)
    resource = Fixtures.Resources.create_resource(account: account)

    attrs =
      Fixtures.Policies.policy_attrs()
      |> Map.take([:name])
      |> Map.put(:actor_group_id, group.id)
      |> Map.put(:resource_id, resource.id)

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/policies/new")

    assert lv
           |> form("form", policy: attrs)
           |> render_submit()

    policy = Repo.get_by(Domain.Policies.Policy, attrs)

    assert assert_redirect(lv, ~p"/#{account}/policies/#{policy}")
  end
end
