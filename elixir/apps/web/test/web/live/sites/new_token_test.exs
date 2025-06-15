defmodule Web.Live.Sites.NewTokenTest do
  use Web.ConnCase, async: true

  setup do
    account = Fixtures.Accounts.create_account()
    actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
    identity = Fixtures.Auth.create_identity(account: account, actor: actor)
    group = Fixtures.Gateways.create_group(account: account)

    %{
      account: account,
      actor: actor,
      identity: identity,
      group: group
    }
  end

  test "creates a new group on valid attrs and redirects when gateway is connected", %{
    account: account,
    identity: identity,
    group: group,
    conn: conn
  } do
    {:ok, lv, html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/sites/#{group}/new_token")

    assert html =~ "Select deployment method"
    assert html =~ "FIREZONE_TOKEN="
    assert html =~ "docker run"
    assert html =~ "Waiting for connection..."

    token =
      Regex.run(~r/FIREZONE_TOKEN=([^&\n ]+)/, html)
      |> List.last()
      |> String.trim("&quot;")

    :ok = Domain.Gateways.Presence.Group.subscribe(group.id)
    context = Fixtures.Auth.build_context(type: :gateway_group)
    assert {:ok, group, token} = Domain.Gateways.authenticate(token, context)
    gateway = Fixtures.Gateways.create_gateway(account: account, group: group, token: token)
    :ok = Domain.Gateways.Presence.connect(gateway)

    assert_receive %Phoenix.Socket.Broadcast{topic: "presences:group_gateways:" <> _group_id}

    wait_for(fn ->
      assert element(lv, "#connection-status")
             |> render() =~ "Connected, click to continue"
    end)
  end
end
