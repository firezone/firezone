defmodule PortalWeb.UnsubscribeTest do
  use PortalWeb.ConnCase, async: true

  import Portal.AccountFixtures
  import Portal.ActorFixtures

  alias Portal.UnsubscribeToken

  setup do
    account = account_fixture()
    actor = admin_actor_fixture(account: account)
    %{account: account, actor: actor}
  end

  test "turns the notification off and says which one", %{
    conn: conn,
    account: account,
    actor: actor
  } do
    token = UnsubscribeToken.sign(actor, :outdated_gateways)

    {:ok, _lv, html} = live(conn, ~p"/#{account.id}/unsubscribe/#{token}")

    assert html =~ "Notifications turned off"
    assert html =~ "Gateway upgrade available"
    assert html =~ account.name
    assert html =~ ~p"/#{account}/settings/profile"

    preferences = preferences(actor)
    assert preferences.notifications.outdated_gateways == []
    assert preferences.notifications.seat_limit_warnings == nil
    assert preferences.notifications.product_announcements == nil
    assert preferences.start_page == :sites
  end

  test "keeps the actor's other settings", %{conn: conn, account: account, actor: actor} do
    actor_preferences_fixture(actor, notifications: %{seat_limit_warnings: []}, start_page: :devices)
    token = UnsubscribeToken.sign(actor, :product_announcements)

    {:ok, _lv, html} = live(conn, ~p"/#{account.id}/unsubscribe/#{token}")

    assert html =~ "Product announcements"

    preferences = preferences(actor)
    assert preferences.notifications.product_announcements == []
    assert preferences.notifications.seat_limit_warnings == []
    assert preferences.notifications.outdated_gateways == nil
    assert preferences.start_page == :devices
  end

  test "does not change anything before the LiveView connects", %{
    conn: conn,
    account: account,
    actor: actor
  } do
    token = UnsubscribeToken.sign(actor, :outdated_gateways)

    html = conn |> get(~p"/#{account.id}/unsubscribe/#{token}") |> html_response(200)

    assert html =~ "Turning off notifications"
    assert preferences(actor) == nil
  end

  test "using the link again keeps the notification off", %{
    conn: conn,
    account: account,
    actor: actor
  } do
    token = UnsubscribeToken.sign(actor, :outdated_gateways)

    {:ok, _lv, _html} = live(conn, ~p"/#{account.id}/unsubscribe/#{token}")
    {:ok, _lv, html} = live(conn, ~p"/#{account.id}/unsubscribe/#{token}")

    assert html =~ "Notifications turned off"
    assert preferences(actor).notifications.outdated_gateways == []
  end

  test "rejects an expired token", %{conn: conn, account: account, actor: actor} do
    token =
      UnsubscribeToken.sign(actor, :outdated_gateways,
        signed_at: System.system_time(:second) - 91 * 24 * 60 * 60
      )

    {:ok, _lv, html} = live(conn, ~p"/#{account.id}/unsubscribe/#{token}")

    assert html =~ "This link is not valid or has expired."
    assert preferences(actor) == nil
  end

  test "rejects a token from another account", %{conn: conn, actor: actor} do
    other_account = account_fixture()
    token = UnsubscribeToken.sign(actor, :outdated_gateways)

    {:ok, _lv, html} = live(conn, ~p"/#{other_account.id}/unsubscribe/#{token}")

    assert html =~ "This link is not valid or has expired."
    assert preferences(actor) == nil
  end

  test "rejects a changed token", %{conn: conn, account: account, actor: actor} do
    other_admin = admin_actor_fixture(account: account)
    [prefix, _payload, signature] = String.split(UnsubscribeToken.sign(actor, :outdated_gateways), ".")
    [_prefix, other_payload, _signature] = String.split(UnsubscribeToken.sign(other_admin, :outdated_gateways), ".")
    changed_token = Enum.join([prefix, other_payload, signature], ".")

    {:ok, _lv, html} = live(conn, ~p"/#{account.id}/unsubscribe/#{changed_token}")

    assert html =~ "This link is not valid or has expired."
    assert preferences(other_admin) == nil
  end

  test "rejects an unknown token", %{conn: conn, account: account} do
    {:ok, _lv, html} = live(conn, ~p"/#{account.id}/unsubscribe/not-a-token")

    assert html =~ "This link is not valid or has expired."
  end

  test "rejects an unknown account", %{conn: conn, actor: actor} do
    token = UnsubscribeToken.sign(actor, :outdated_gateways)

    {:ok, _lv, html} = live(conn, ~p"/#{Ecto.UUID.generate()}/unsubscribe/#{token}")

    assert html =~ "This link is not valid or has expired."
    refute html =~ "Manage your notifications"
  end

  defp preferences(actor) do
    Portal.Repo.get_by!(Portal.Actor, id: actor.id).preferences
  end
end
