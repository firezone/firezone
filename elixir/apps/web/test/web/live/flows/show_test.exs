defmodule Web.Live.Flows.ShowTest do
  use Web.ConnCase, async: true

  setup do
    account = Fixtures.Accounts.create_account()
    actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
    identity = Fixtures.Auth.create_identity(account: account, actor: actor)
    subject = Fixtures.Auth.create_subject(account: account, actor: actor, identity: identity)

    client = Fixtures.Clients.create_client(account: account, actor: actor, identity: identity)
    flow = Fixtures.Flows.create_flow(account: account, client: client)

    %{
      account: account,
      actor: actor,
      identity: identity,
      subject: subject,
      client: client,
      flow: flow
    }
  end

  test "redirects to sign in page for unauthorized user", %{
    account: account,
    flow: flow,
    conn: conn
  } do
    path = ~p"/#{account}/flows/#{flow}"

    assert live(conn, path) ==
             {:error,
              {:redirect,
               %{
                 to: ~p"/#{account}?#{%{redirect_to: path}}",
                 flash: %{"error" => "You must sign in to access this page."}
               }}}
  end

  test "renders 404 error when flow activities are not enabled", %{
    account: account,
    identity: identity,
    flow: flow,
    conn: conn
  } do
    {:ok, account} =
      Domain.Accounts.update_account(account, %{
        features: %{
          flow_activities: false
        }
      })

    assert_raise Web.LiveErrors.NotFoundError, fn ->
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/flows/#{flow}") =~ "404"
    end
  end

  test "renders breadcrumbs item", %{
    account: account,
    flow: flow,
    client: client,
    identity: identity,
    conn: conn
  } do
    {:ok, _lv, html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/flows/#{flow}")

    assert item = Floki.find(html, "[aria-label='Breadcrumb']")
    breadcrumbs = String.trim(Floki.text(item))
    assert breadcrumbs =~ "Flows"
    assert breadcrumbs =~ "#{client.name} flow"
  end

  test "renders flows details", %{
    account: account,
    identity: identity,
    flow: flow,
    conn: conn
  } do
    flow =
      Repo.preload(flow,
        policy: [:resource, :actor_group],
        client: [],
        gateway: [:group],
        resource: []
      )

    activity =
      Fixtures.Flows.create_activity(
        account: account,
        flow: flow,
        window_started_at: DateTime.truncate(flow.inserted_at, :second),
        window_ended_at: DateTime.truncate(flow.expires_at, :second)
      )

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/flows/#{flow}")

    table =
      lv
      |> element("#flow")
      |> render()
      |> vertical_table_to_map()

    assert table["authorized at"]
    assert table["expires at"]

    assert table["connectivity type"] =~ to_string(activity.connectivity_type)

    assert table["client"] =~ flow.client.name
    assert table["client"] =~ to_string(flow.client_remote_ip)
    assert table["client"] =~ flow.client_user_agent

    assert table["gateway"] =~ flow.gateway.name
    assert table["gateway"] =~ to_string(flow.gateway_remote_ip)

    assert table["resource"] =~ flow.resource.name

    assert table["policy"] =~ flow.policy.resource.name
    assert table["policy"] =~ flow.policy.actor_group.name
  end

  test "allows downloading activities", %{
    account: account,
    flow: flow,
    identity: identity,
    conn: conn
  } do
    activity =
      Fixtures.Flows.create_activity(
        account: account,
        flow: flow,
        window_started_at: DateTime.truncate(flow.inserted_at, :second),
        window_ended_at: DateTime.truncate(flow.expires_at, :second)
      )

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/flows/#{flow}")

    lv
    |> element("a", "Export to CSV")
    |> render_click()

    assert_redirected(lv, ~p"/#{account}/flows/#{flow}/activities.csv")

    controller_conn = get(conn, ~p"/#{account}/flows/#{flow}/activities.csv")
    assert redirected_to(controller_conn) =~ ~p"/#{account}"
    assert flash(controller_conn, :error) == "You must sign in to access this page."

    controller_conn =
      conn
      |> authorize_conn(identity)
      |> get(~p"/#{account}/flows/#{flow}/activities.csv")

    assert response = response(controller_conn, 200)

    assert response
           |> String.trim()
           |> String.split("\n")
           |> Enum.map(&String.split(&1, "\t")) ==
             [
               [
                 "window_started_at",
                 "window_ended_at",
                 "destination",
                 "connectivity_type",
                 "rx_bytes",
                 "tx_bytes",
                 "blocked_tx_bytes"
               ],
               [
                 to_string(activity.window_started_at),
                 to_string(activity.window_ended_at),
                 to_string(activity.destination),
                 to_string(activity.connectivity_type),
                 to_string(activity.rx_bytes),
                 to_string(activity.tx_bytes),
                 to_string(activity.blocked_tx_bytes)
               ]
             ]
  end

  test "renders activities table", %{
    account: account,
    flow: flow,
    identity: identity,
    conn: conn
  } do
    activity =
      Fixtures.Flows.create_activity(
        account: account,
        flow: flow,
        window_started_at: DateTime.truncate(flow.inserted_at, :second),
        window_ended_at: DateTime.truncate(flow.expires_at, :second),
        tx_bytes: 1024 * 1024 * 1024 * 42
      )

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/flows/#{flow}")

    [row] =
      lv
      |> element("#activities")
      |> render()
      |> table_to_map()

    assert row["started"]
    assert row["ended"]

    assert row["connectivity type"] == to_string(activity.connectivity_type)
    assert row["destination"] == to_string(activity.destination)
    assert row["rx"] == "#{activity.rx_bytes} B"
    assert row["tx"] == "42 GB"
  end
end
