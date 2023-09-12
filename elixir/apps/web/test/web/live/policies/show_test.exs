defmodule Web.Live.Policies.ShowTest do
  use Web.ConnCase, async: true

  setup do
    account = Fixtures.Accounts.create_account()
    actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
    identity = Fixtures.Auth.create_identity(account: account, actor: actor)
    subject = Fixtures.Auth.create_subject(account: account, actor: actor, identity: identity)

    policy = Fixtures.Policies.create_policy(account: account, subject: subject)

    %{
      account: account,
      actor: actor,
      identity: identity,
      subject: subject,
      policy: policy
    }
  end

  test "redirects to sign in page for unauthorized user", %{
    account: account,
    policy: policy,
    conn: conn
  } do
    assert live(conn, ~p"/#{account}/policies/#{policy}") ==
             {:error,
              {:redirect,
               %{
                 to: ~p"/#{account}/sign_in",
                 flash: %{"error" => "You must log in to access this page."}
               }}}
  end

  test "renders not found error when gateway is deleted", %{
    account: account,
    policy: policy,
    identity: identity,
    conn: conn
  } do
    policy = Fixtures.Policies.delete_policy(policy)

    assert_raise Web.LiveErrors.NotFoundError, fn ->
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/policies/#{policy}")
    end
  end

  test "renders breadcrumbs item", %{
    account: account,
    policy: policy,
    identity: identity,
    conn: conn
  } do
    {:ok, _lv, html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/policies/#{policy}")

    assert item = Floki.find(html, "[aria-label='Breadcrumb']")
    breadcrumbs = String.trim(Floki.text(item))
    assert breadcrumbs =~ "Policies"
    assert breadcrumbs =~ policy.name
  end

  test "allows editing policy", %{
    account: account,
    policy: policy,
    identity: identity,
    conn: conn
  } do
    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/policies/#{policy}")

    assert lv
           |> element("a", "Edit Policy")
           |> render_click() ==
             {:error,
              {:live_redirect, %{to: ~p"/#{account}/policies/#{policy}/edit", kind: :push}}}
  end

  test "renders policy details", %{
    account: account,
    actor: actor,
    identity: identity,
    policy: policy,
    conn: conn
  } do
    policy =
      policy
      |> Domain.Repo.preload(:actor_group)
      |> Domain.Repo.preload(:resource)

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/policies/#{policy}")

    table =
      lv
      |> element("#policy")
      |> render()
      |> vertical_table_to_map()

    assert table["name"] =~ policy.name
    assert table["group"] =~ policy.actor_group.name
    assert table["resource"] =~ policy.resource.name
    assert table["created"] =~ actor.name
  end

  # TODO: Finish this test when logs are implemented
  # test "renders logs table", %{
  #  account: account,
  #  actor: actor,
  #  identity: identity,
  #  policy: policy,
  #  conn: conn
  # } do
  #  {:ok, lv, _html} =
  #    conn
  #    |> authorize_conn(identity)
  #    |> live(~p"/#{account}/policies/#{policy}")
  # end

  test "allows deleting policy", %{
    account: account,
    policy: policy,
    identity: identity,
    conn: conn
  } do
    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/policies/#{policy}")

    assert lv
           |> element("button", "Delete Policy")
           |> render_click() ==
             {:error, {:live_redirect, %{to: ~p"/#{account}/policies", kind: :push}}}

    assert Repo.get(Domain.Policies.Policy, policy.id).deleted_at
  end
end
