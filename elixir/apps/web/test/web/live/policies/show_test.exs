defmodule Web.Live.Policies.ShowTest do
  use Web.ConnCase, async: true

  setup do
    account = Fixtures.Accounts.create_account()
    actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
    identity = Fixtures.Auth.create_identity(account: account, actor: actor)
    subject = Fixtures.Auth.create_subject(account: account, actor: actor, identity: identity)

    resource = Fixtures.Resources.create_resource(account: account)

    policy =
      Fixtures.Policies.create_policy(
        account: account,
        subject: subject,
        resource: resource,
        description: "Test Policy"
      )

    policy = Repo.preload(policy, [:actor_group, :resource])

    %{
      account: account,
      actor: actor,
      identity: identity,
      subject: subject,
      resource: resource,
      policy: policy
    }
  end

  test "redirects to sign in page for unauthorized user", %{
    account: account,
    policy: policy,
    conn: conn
  } do
    path = ~p"/#{account}/policies/#{policy}"

    assert live(conn, path) ==
             {:error,
              {:redirect,
               %{
                 to: ~p"/#{account}?#{%{redirect_to: path}}",
                 flash: %{"error" => "You must sign in to access this page."}
               }}}
  end

  test "renders deleted gateway group without action buttons", %{
    account: account,
    policy: policy,
    identity: identity,
    conn: conn
  } do
    policy = Fixtures.Policies.delete_policy(policy)

    {:ok, _lv, html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/policies/#{policy}")

    assert html =~ "(deleted)"
    assert active_buttons(html) == []
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
    assert breadcrumbs =~ policy.actor_group.name
    assert breadcrumbs =~ policy.resource.name
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

    assert table["group"] =~ policy.actor_group.name
    assert table["resource"] =~ policy.resource.name
    assert table["description"] =~ policy.description
    assert table["created"] =~ actor.name
  end

  test "renders logs table", %{
    account: account,
    identity: identity,
    resource: resource,
    policy: policy,
    conn: conn
  } do
    flow =
      Fixtures.Flows.create_flow(
        account: account,
        resource: resource,
        policy: policy
      )

    flow = Repo.preload(flow, client: [:actor], gateway: [:group])

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/policies/#{policy}")

    [row] =
      lv
      |> element("#flows")
      |> render()
      |> table_to_map()

    assert row["authorized at"]
    assert row["expires at"]
    assert row["client, actor (ip)"] =~ flow.client.name
    assert row["client, actor (ip)"] =~ "owned by #{flow.client.actor.name}"
    assert row["client, actor (ip)"] =~ to_string(flow.client_remote_ip)

    assert row["gateway (ip)"] =~
             "#{flow.gateway.group.name}-#{flow.gateway.name} (#{flow.gateway.last_seen_remote_ip})"
  end

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

    {:ok, _lv, html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/policies/#{policy}")

    assert html =~ "(deleted)"
  end

  test "allows disabling and enabling policy", %{
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
           |> element("button", "Disable")
           |> render_click() =~ "(disabled)"

    assert Repo.get(Domain.Policies.Policy, policy.id).disabled_at

    refute lv
           |> element("button", "Enable")
           |> render_click() =~ "(disabled)"

    refute Repo.get(Domain.Policies.Policy, policy.id).disabled_at
  end
end
