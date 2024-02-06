defmodule Web.Live.Policies.NewTest do
  use Web.ConnCase, async: true

  setup do
    account = Fixtures.Accounts.create_account()
    actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
    actor_group = Fixtures.Actors.create_group(account: account)
    identity = Fixtures.Auth.create_identity(account: account, actor: actor)

    %{
      account: account,
      actor: actor,
      actor_group: actor_group,
      identity: identity
    }
  end

  test "redirects to sign in page for unauthorized user", %{
    account: account,
    conn: conn
  } do
    path = ~p"/#{account}/policies/new"

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
             "policy[description]",
             "policy[resource_id]"
           ]
  end

  test "renders form with pre-set resource_id", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    resource = Fixtures.Resources.create_resource(account: account)

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/policies/new?resource_id=#{resource.id}")

    form = form(lv, "form")

    assert find_inputs(form) == [
             "policy[actor_group_id]",
             "policy[description]",
             "policy[resource_id]"
           ]

    disabled_input = render(form) |> Floki.find("select[name='policy[resource_id]']")
    assert Floki.attribute(disabled_input, "disabled") == ["disabled"]

    assert disabled_input |> Floki.find("option[selected=selected]") |> Floki.attribute("value") ==
             [resource.id]
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
    |> validate_change(%{policy: %{description: String.duplicate("a", 1025)}}, fn form, _html ->
      assert form_validation_errors(form) == %{
               "policy[description]" => ["should be at most 1024 character(s)"]
             }
    end)
  end

  test "renders changeset errors on submit", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    other_policy = Fixtures.Policies.create_policy(account: account)
    attrs = %{description: String.duplicate("a", 1025)}

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/policies/new")

    assert lv
           |> form("form", policy: attrs)
           |> render_submit()
           |> form_validation_errors() == %{
             "policy[description]" => ["should be at most 1024 character(s)"]
           }

    attrs = %{
      description: "",
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

  test "creates a new policy on valid attrs and redirects to policy page", %{
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

  test "creates a new policy on valid attrs and pre-set resource_id", %{
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

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/policies/new?resource_id=#{resource}")

    assert lv
           |> form("form", policy: attrs)
           |> render_submit()

    policy = Repo.get_by(Domain.Policies.Policy, attrs)
    assert policy.resource_id == resource.id

    assert assert_redirect(lv, ~p"/#{account}/policies/#{policy}")
  end

  test "redirects back to site when a new policy is created with pre-set site_id", %{
    account: account,
    identity: identity,
    conn: conn
  } do
    group = Fixtures.Actors.create_group(account: account)
    resource = Fixtures.Resources.create_resource(account: account)

    gateway_group = Fixtures.Gateways.create_group(account: account)

    attrs =
      Fixtures.Policies.policy_attrs()
      |> Map.take([:name])
      |> Map.put(:actor_group_id, group.id)

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/policies/new?site_id=#{gateway_group.id}")

    assert lv
           |> form("form", policy: attrs)
           |> render_submit()

    policy = Repo.get_by(Domain.Policies.Policy, attrs)
    assert policy.resource_id == resource.id

    assert assert_redirect(lv, ~p"/#{account}/sites/#{gateway_group}?#resources")
  end
end
