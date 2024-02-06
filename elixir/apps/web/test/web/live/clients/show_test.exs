defmodule Web.Live.Clients.ShowTest do
  use Web.ConnCase, async: true

  setup do
    account = Fixtures.Accounts.create_account()
    actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
    identity = Fixtures.Auth.create_identity(account: account, actor: actor)
    subject = Fixtures.Auth.create_subject(account: account, actor: actor, identity: identity)

    client = Fixtures.Clients.create_client(account: account, actor: actor, identity: identity)

    %{
      account: account,
      actor: actor,
      identity: identity,
      subject: subject,
      client: client
    }
  end

  test "redirects to sign in page for unauthorized user", %{
    account: account,
    client: client,
    conn: conn
  } do
    path = ~p"/#{account}/clients/#{client}"

    assert live(conn, path) ==
             {:error,
              {:redirect,
               %{
                 to: ~p"/#{account}?#{%{redirect_to: path}}",
                 flash: %{"error" => "You must sign in to access this page."}
               }}}
  end

  test "renders deleted client without action buttons", %{
    account: account,
    client: client,
    identity: identity,
    conn: conn
  } do
    client = Fixtures.Clients.delete_client(client)

    {:ok, _lv, html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/clients/#{client}")

    assert html =~ "(deleted)"
    assert active_buttons(html) == []
  end

  test "renders breadcrumbs item", %{
    account: account,
    client: client,
    identity: identity,
    conn: conn
  } do
    {:ok, _lv, html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/clients/#{client}")

    assert item = Floki.find(html, "[aria-label='Breadcrumb']")
    breadcrumbs = String.trim(Floki.text(item))
    assert breadcrumbs =~ "Clients"
    assert breadcrumbs =~ client.name
  end

  test "renders client details", %{
    account: account,
    client: client,
    actor: actor,
    identity: identity,
    conn: conn
  } do
    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/clients/#{client}")

    table =
      lv
      |> element("#client")
      |> render()
      |> vertical_table_to_map()

    assert table["identifier"] == client.id
    assert table["name"] == client.name
    assert table["owner"] =~ actor.name
    assert table["status"] =~ "Offline"
    assert table["created"]
    assert table["last seen"]
    assert table["last seen remote ip"] =~ to_string(client.last_seen_remote_ip)
    assert table["client version"] =~ client.last_seen_version
    assert table["user agent"] =~ client.last_seen_user_agent
  end

  test "renders client owner", %{
    account: account,
    client: client,
    identity: identity,
    conn: conn
  } do
    actor = Repo.preload(client, :actor).actor

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/clients/#{client}")

    assert lv
           |> element("#client")
           |> render()
           |> vertical_table_to_map()
           |> Map.fetch!("owner") =~ actor.name
  end

  test "renders flows table", %{
    account: account,
    identity: identity,
    client: client,
    conn: conn
  } do
    flow =
      Fixtures.Flows.create_flow(
        account: account,
        client: client
      )

    flow = Repo.preload(flow, [:client, gateway: [:group], policy: [:actor_group, :resource]])

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/clients/#{client}")

    [row] =
      lv
      |> element("#flows")
      |> render()
      |> table_to_map()

    assert row["authorized at"]
    assert row["expires at"]
    assert row["remote ip"] == to_string(client.last_seen_remote_ip)
    assert row["policy"] =~ flow.policy.actor_group.name
    assert row["policy"] =~ flow.policy.resource.name

    assert row["gateway (ip)"] ==
             "#{flow.gateway.group.name}-#{flow.gateway.name} (#{flow.gateway.last_seen_remote_ip})"
  end

  test "renders flows even for deleted policies", %{
    account: account,
    identity: identity,
    client: client,
    conn: conn
  } do
    flow =
      Fixtures.Flows.create_flow(
        account: account,
        client: client
      )

    flow = Repo.preload(flow, [:client, gateway: [:group], policy: [:actor_group, :resource]])
    Fixtures.Policies.delete_policy(flow.policy)

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/clients/#{client}")

    [row] =
      lv
      |> element("#flows")
      |> render()
      |> table_to_map()

    assert row["authorized at"]
    assert row["expires at"]
    assert row["remote ip"] == to_string(client.last_seen_remote_ip)
    assert row["policy"] =~ flow.policy.actor_group.name
    assert row["policy"] =~ flow.policy.resource.name

    assert row["gateway (ip)"] ==
             "#{flow.gateway.group.name}-#{flow.gateway.name} (#{flow.gateway.last_seen_remote_ip})"
  end

  test "renders flows even for deleted policy assocs", %{
    account: account,
    identity: identity,
    client: client,
    conn: conn
  } do
    flow =
      Fixtures.Flows.create_flow(
        account: account,
        client: client
      )

    flow = Repo.preload(flow, [:client, gateway: [:group], policy: [:actor_group, :resource]])
    Fixtures.Actors.delete_group(flow.policy.actor_group)
    Fixtures.Resources.delete_resource(flow.policy.resource)

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/clients/#{client}")

    [row] =
      lv
      |> element("#flows")
      |> render()
      |> table_to_map()

    assert row["authorized at"]
    assert row["expires at"]
    assert row["remote ip"] == to_string(client.last_seen_remote_ip)
    assert row["policy"] =~ flow.policy.actor_group.name
    assert row["policy"] =~ flow.policy.resource.name

    assert row["gateway (ip)"] ==
             "#{flow.gateway.group.name}-#{flow.gateway.name} (#{flow.gateway.last_seen_remote_ip})"
  end

  test "allows editing clients", %{
    account: account,
    client: client,
    identity: identity,
    conn: conn
  } do
    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/clients/#{client}")

    assert lv
           |> element("a", "Edit")
           |> render_click() ==
             {:error,
              {:live_redirect, %{to: ~p"/#{account}/clients/#{client}/edit", kind: :push}}}
  end
end
