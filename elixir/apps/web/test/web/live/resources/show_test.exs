defmodule Web.Live.Resources.ShowTest do
  use Web.ConnCase, async: true

  setup do
    account = Fixtures.Accounts.create_account()
    actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
    identity = Fixtures.Auth.create_identity(account: account, actor: actor)
    subject = Fixtures.Auth.create_subject(account: account, actor: actor, identity: identity)

    group = Fixtures.Gateways.create_group(account: account, subject: subject)
    gateway = Fixtures.Gateways.create_gateway(account: account, group: group)
    gateway = Repo.preload(gateway, :group)

    resource =
      Fixtures.Resources.create_resource(
        account: account,
        subject: subject,
        connections: [%{gateway_group_id: group.id}]
      )

    %{
      account: account,
      actor: actor,
      identity: identity,
      subject: subject,
      group: group,
      gateway: gateway,
      resource: resource
    }
  end

  test "redirects to sign in page for unauthorized user", %{
    account: account,
    resource: resource,
    conn: conn
  } do
    path = ~p"/#{account}/resources/#{resource}"

    assert live(conn, path) ==
             {:error,
              {:redirect,
               %{
                 to: ~p"/#{account}?#{%{redirect_to: path}}",
                 flash: %{"error" => "You must log in to access this page."}
               }}}
  end

  test "renders deleted resource without action buttons", %{
    account: account,
    resource: resource,
    identity: identity,
    conn: conn
  } do
    resource = Fixtures.Resources.delete_resource(resource)

    {:ok, _lv, html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/resources/#{resource}")

    assert html =~ "(deleted)"
    assert active_buttons(html) == []
  end

  test "renders breadcrumbs item", %{
    account: account,
    resource: resource,
    identity: identity,
    conn: conn
  } do
    {:ok, _lv, html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/resources/#{resource}")

    assert item = Floki.find(html, "[aria-label='Breadcrumb']")
    breadcrumbs = String.trim(Floki.text(item))
    assert breadcrumbs =~ "Resources"
    assert breadcrumbs =~ resource.name
  end

  test "allows editing resource", %{
    account: account,
    resource: resource,
    identity: identity,
    conn: conn
  } do
    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/resources/#{resource}")

    assert lv
           |> element("a", "Edit Resource")
           |> render_click() ==
             {:error,
              {:live_redirect, %{to: ~p"/#{account}/resources/#{resource}/edit", kind: :push}}}
  end

  test "hides edit resource button when feature is disabled", %{
    account: account,
    resource: resource,
    identity: identity,
    conn: conn
  } do
    Domain.Config.feature_flag_override(:multi_site_resources, false)

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/resources/#{resource}")

    refute has_element?(lv, "a", "Edit Resource")
  end

  test "renders resource details", %{
    account: account,
    actor: actor,
    identity: identity,
    resource: resource,
    conn: conn
  } do
    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/resources/#{resource}")

    table =
      lv
      |> element("#resource")
      |> render()
      |> vertical_table_to_map()

    assert table["name"] =~ resource.name
    assert table["address"] =~ resource.address
    assert table["created"] =~ actor.name
    assert table["authorized groups"] == "None, create a Policy to grant access."

    for filter <- resource.filters do
      assert String.downcase(table["traffic filtering rules"]) =~ Atom.to_string(filter.protocol)
    end
  end

  test "renders authorized groups peek", %{
    account: account,
    identity: identity,
    resource: resource,
    conn: conn
  } do
    policies =
      [
        Fixtures.Policies.create_policy(
          account: account,
          resource: resource
        ),
        Fixtures.Policies.create_policy(
          account: account,
          resource: resource
        ),
        Fixtures.Policies.create_policy(
          account: account,
          resource: resource
        )
      ]
      |> Repo.preload(:actor_group)

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/resources/#{resource}")

    table =
      lv
      |> element("#resource")
      |> render()
      |> vertical_table_to_map()

    for policy <- policies do
      assert table["authorized groups"] =~ policy.actor_group.name
    end

    Fixtures.Policies.create_policy(
      account: account,
      resource: resource
    )

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/resources/#{resource}")

    table =
      lv
      |> element("#resource")
      |> render()
      |> vertical_table_to_map()

    assert table["authorized groups"] =~ "and 1 more"
  end

  test "renders gateway groups row", %{
    account: account,
    identity: identity,
    group: group,
    resource: resource,
    conn: conn
  } do
    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/resources/#{resource}")

    table =
      lv
      |> element("#resource")
      |> render()
      |> vertical_table_to_map()

    assert table["connected sites"] =~ group.name
  end

  test "renders logs table", %{
    account: account,
    identity: identity,
    resource: resource,
    conn: conn
  } do
    flow =
      Fixtures.Flows.create_flow(
        account: account,
        resource: resource
      )

    flow =
      Repo.preload(flow, client: [:actor], gateway: [:group], policy: [:actor_group, :resource])

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/resources/#{resource}")

    [row] =
      lv
      |> element("#flows")
      |> render()
      |> table_to_map()

    assert row["authorized at"]
    assert row["expires at"]
    assert row["policy"] =~ flow.policy.actor_group.name
    assert row["policy"] =~ flow.policy.resource.name

    assert row["gateway (ip)"] ==
             "#{flow.gateway.group.name}-#{flow.gateway.name} (189.172.73.153)"

    assert row["client, actor (ip)"] =~ flow.client.name
    assert row["client, actor (ip)"] =~ "owned by #{flow.client.actor.name}"
    assert row["client, actor (ip)"] =~ to_string(flow.client_remote_ip)
  end

  test "allows deleting resource", %{
    account: account,
    resource: resource,
    identity: identity,
    conn: conn
  } do
    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/resources/#{resource}")

    assert lv
           |> element("button", "Delete Resource")
           |> render_click() ==
             {:error, {:live_redirect, %{to: ~p"/#{account}/resources", kind: :push}}}

    assert Repo.get(Domain.Resources.Resource, resource.id).deleted_at
  end
end
