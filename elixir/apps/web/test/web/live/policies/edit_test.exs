defmodule Web.Live.Policies.EditTest do
  use Web.ConnCase, async: true

  setup do
    account = Fixtures.Accounts.create_account()
    actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
    identity = Fixtures.Auth.create_identity(account: account, actor: actor)

    resource = Fixtures.Resources.create_resource(account: account)

    policy =
      Fixtures.Policies.create_policy(
        account: account,
        resource: resource,
        description: "Test Policy"
      )

    policy = Repo.preload(policy, [:actor_group, :resource])

    %{
      account: account,
      actor: actor,
      identity: identity,
      resource: resource,
      policy: policy
    }
  end

  test "redirects to sign in page for unauthorized user", %{
    account: account,
    policy: policy,
    conn: conn
  } do
    path = ~p"/#{account}/policies/#{policy}/edit"

    assert live(conn, path) ==
             {:error,
              {:redirect,
               %{
                 to: ~p"/#{account}?#{%{redirect_to: path}}",
                 flash: %{"error" => "You must log in to access this page."}
               }}}
  end

  test "renders not found error when policy is deleted", %{
    account: account,
    identity: identity,
    policy: policy,
    conn: conn
  } do
    Fixtures.Policies.delete_policy(policy)

    assert_raise Web.LiveErrors.NotFoundError, fn ->
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/policies/#{policy}/edit")
    end
  end

  test "renders breadcrumbs item", %{
    account: account,
    identity: identity,
    policy: policy,
    conn: conn
  } do
    {:ok, _lv, html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/policies/#{policy}/edit")

    assert item = Floki.find(html, "[aria-label='Breadcrumb']")
    breadcrumbs = String.trim(Floki.text(item))
    assert breadcrumbs =~ "Policies"
    assert breadcrumbs =~ policy.actor_group.name
    assert breadcrumbs =~ policy.resource.name
    assert breadcrumbs =~ "Edit"
  end

  test "renders form", %{
    account: account,
    identity: identity,
    policy: policy,
    conn: conn
  } do
    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/policies/#{policy}/edit")

    form = form(lv, "form")

    assert find_inputs(form) == ["policy[description]"]
  end

  test "renders changeset errors on input change", %{
    account: account,
    identity: identity,
    policy: policy,
    conn: conn
  } do
    attrs = Fixtures.Policies.policy_attrs() |> Map.take([:description])

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/policies/#{policy}/edit")

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
    policy: policy,
    conn: conn
  } do
    attrs = %{description: String.duplicate("a", 1025)}

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/policies/#{policy}/edit")

    assert lv
           |> form("form", policy: attrs)
           |> render_submit()
           |> form_validation_errors() == %{
             "policy[description]" => ["should be at most 1024 character(s)"]
           }
  end

  test "updates a policy on valid attrs", %{
    account: account,
    identity: identity,
    policy: policy,
    conn: conn
  } do
    attrs = Fixtures.Policies.policy_attrs() |> Map.take([:description])

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/policies/#{policy}/edit")

    lv
    |> form("form", policy: attrs)
    |> render_submit()

    assert_redirected(lv, ~p"/#{account}/policies/#{policy}")

    assert policy = Repo.get_by(Domain.Policies.Policy, id: policy.id)
    assert policy.description == attrs.description
  end
end
