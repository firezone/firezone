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
    assert html =~ "Waiting for gateway connection..."

    assert Regex.run(~r/FIREZONE_ID=([^ ]+)/, html) |> List.last()
    token = Regex.run(~r/FIREZONE_TOKEN=([^ ]+)/, html) |> List.last() |> String.trim("&quot;")
    assert {:ok, _token} = Domain.Gateways.authorize_gateway(token)

    gateway = Fixtures.Gateways.create_gateway(account: account, group: group)
    Domain.Gateways.connect_gateway(gateway)

    assert assert_redirect(lv, ~p"/#{account}/sites/#{group}")
  end
end
