defmodule Web.Live.Sites.Gateways.IndexTest do
  use Web.ConnCase, async: true

  setup do
    account = Fixtures.Accounts.create_account()
    identity = Fixtures.Auth.create_identity(account: account, actor: [type: :account_admin_user])
    group = Fixtures.Gateways.create_group(account: account)

    %{
      account: account,
      identity: identity,
      group: group
    }
  end

  test "redirects to sign in page for unauthorized user", %{
    account: account,
    group: group,
    conn: conn
  } do
    path = ~p"/#{account}/sites/#{group}/gateways"

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
    group: group,
    conn: conn
  } do
    {:ok, _lv, html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/sites/#{group}/gateways")

    assert item = Floki.find(html, "[aria-label='Breadcrumb']")
    breadcrumbs = String.trim(Floki.text(item))
    assert breadcrumbs =~ "Sites"
  end

  test "renders gateways table", %{
    account: account,
    identity: identity,
    group: group,
    conn: conn
  } do
    gateway =
      Fixtures.Gateways.create_gateway(
        account: account,
        group: group,
        context: %{user_agent: "iOS/12.5 (iPhone) connlib/1.3.2"}
      )

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/sites/#{group}/gateways")

    [row] =
      lv
      |> element("#gateways")
      |> render()
      |> table_to_map()

    assert row == %{
             "instance" => gateway.name,
             "remote ip" => to_string(gateway.last_seen_remote_ip),
             "status" => "Offline",
             "version" => "1.3.2"
           }
  end

  test "updates gateways table using presence events", %{
    account: account,
    identity: identity,
    group: group,
    conn: conn
  } do
    gateway =
      Fixtures.Gateways.create_gateway(
        account: account,
        group: group,
        context: %{user_agent: "iOS/12.5 (iPhone) connlib/1.3.2"}
      )

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/sites/#{group}/gateways")

    :ok = Domain.Gateways.subscribe_to_gateways_presence_in_group(group)
    :ok = Domain.Gateways.connect_gateway(gateway)
    assert_receive %Phoenix.Socket.Broadcast{topic: "presences:group_gateways:" <> _}

    wait_for(fn ->
      [row] =
        lv
        |> element("#gateways")
        |> render()
        |> table_to_map()

      assert row == %{
               "instance" => gateway.name,
               "remote ip" => to_string(gateway.last_seen_remote_ip),
               "status" => "Online",
               "version" => "1.3.2"
             }
    end)
  end
end
