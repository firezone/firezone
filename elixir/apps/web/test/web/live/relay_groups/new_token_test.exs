defmodule Web.Live.RelayGroups.NewTokenTest do
  use Web.ConnCase, async: true

  setup do
    account = Fixtures.Accounts.create_account()
    actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
    identity = Fixtures.Auth.create_identity(account: account, actor: actor)
    group = Fixtures.Relays.create_group(account: account)

    %{
      account: account,
      actor: actor,
      identity: identity,
      group: group
    }
  end

  test "creates a new group on valid attrs and redirects when relay is connected", %{
    account: account,
    identity: identity,
    group: group,
    conn: conn
  } do
    {:ok, lv, html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/relay_groups/#{group}/new_token")

    assert html =~ "Select deployment method"
    assert html =~ "FIREZONE_TOKEN="
    assert html =~ "PUBLIC_IP4_ADDR="
    assert html =~ "PUBLIC_IP6_ADDR="
    assert html =~ "docker run"
    assert html =~ "Waiting for connection..."

    assert Regex.run(~r/FIREZONE_ID=([^&]+)/, html) |> List.last()
    token = Regex.run(~r/FIREZONE_TOKEN=([^&]+)/, html) |> List.last() |> String.trim("&quot;")

    :ok = Domain.Relays.subscribe_for_relays_presence_in_group(group)
    relay = Fixtures.Relays.create_relay(account: account, group: group)
    assert {:ok, _token} = Domain.Relays.authorize_relay(token)
    Domain.Relays.connect_relay(relay, "foo")

    assert_receive %Phoenix.Socket.Broadcast{topic: "relay_groups:" <> _group_id}

    assert element(lv, "#connection-status")
           |> render() =~ "Connected, click to continue"
  end

  test "renders not found error when self_hosted_relays feature flag is false", %{
    account: account,
    identity: identity,
    group: group,
    conn: conn
  } do
    Domain.Config.feature_flag_override(:self_hosted_relays, false)

    assert_raise Web.LiveErrors.NotFoundError, fn ->
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/relay_groups/#{group}/new_token")
    end
  end
end
