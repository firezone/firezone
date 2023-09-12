defmodule Web.Live.Policies.EditTest do
  use Web.ConnCase, async: true

  setup do
    account = Fixtures.Accounts.create_account()
    actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
    identity = Fixtures.Auth.create_identity(account: account, actor: actor)

    policy = Fixtures.Policies.create_policy(account: account)

    %{
      account: account,
      actor: actor,
      identity: identity,
      policy: policy
    }
  end

  test "redirects to sign in page for unauthorized user", %{
    account: account,
    policy: policy,
    conn: conn
  } do
    assert live(conn, ~p"/#{account}/policies/#{policy}/edit") ==
             {:error,
              {:redirect,
               %{
                 to: ~p"/#{account}/sign_in",
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
    assert breadcrumbs =~ policy.name
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

    assert find_inputs(form) == ["policy[name]"]
  end

  test "renders changeset errors on input change", %{
    account: account,
    identity: identity,
    policy: policy,
    conn: conn
  } do
    attrs = Fixtures.Policies.policy_attrs() |> Map.take([:name])

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/policies/#{policy}/edit")

    lv
    |> form("form", policy: attrs)
    |> validate_change(%{policy: %{name: String.duplicate("a", 256)}}, fn form, _html ->
      assert form_validation_errors(form) == %{
               "policy[name]" => ["should be at most 255 character(s)"]
             }
    end)
    |> validate_change(%{policy: %{name: ""}}, fn form, _html ->
      assert form_validation_errors(form) == %{"policy[name]" => ["can't be blank"]}
    end)
  end

  test "renders changeset errors on submit", %{
    account: account,
    identity: identity,
    policy: policy,
    conn: conn
  } do
    other_policy = Fixtures.Policies.create_policy(account: account)
    attrs = %{name: other_policy.name}

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/policies/#{policy}/edit")

    assert lv
           |> form("form", policy: attrs)
           |> render_submit()
           |> form_validation_errors() == %{"policy[name]" => ["Policy Name already exists"]}
  end

  test "updates a policy on valid attrs", %{
    account: account,
    identity: identity,
    policy: policy,
    conn: conn
  } do
    attrs = Fixtures.Policies.policy_attrs() |> Map.take([:name])

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/policies/#{policy}/edit")

    assert lv
           |> form("form", policy: attrs)
           |> render_submit() ==
             {:error, {:redirect, %{to: ~p"/#{account}/policies/#{policy}"}}}

    assert policy = Repo.get_by(Domain.Policies.Policy, id: policy.id)
    assert policy.name == attrs.name
  end
end
