defmodule FzHttpWeb.NotificationsLive.BadgeTest do
  @moduledoc """
  Test notifications badge.
  """
  use FzHttpWeb.ConnCase, async: true
  alias FzHttp.Notifications

  setup do
    on_exit(fn -> Notifications.clear() end)
  end

  setup [:create_notifications]

  test "badge has no notifications", %{admin_conn: conn} do
    {:ok, _view, html} = live_isolated(conn, FzHttpWeb.NotificationsLive.Badge)

    assert html =~
             "<span class=\"icon has-text-grey-dark\"><i class=\"mdi mdi-circle-outline\"></i></span>"
  end

  test "badge has 5 notifications after adding 5", %{
    admin_conn: conn,
    notifications: notifications
  } do
    for notification <- notifications do
      Notifications.add(notification)
    end

    {:ok, _view, html} = live_isolated(conn, FzHttpWeb.NotificationsLive.Badge)

    assert html =~ "<span class=\"icon has-text-danger\"><i class=\"mdi mdi-circle\"></i>5</span>"
  end

  test "badge has 3 notifications after adding 5 and clearing 2", %{
    admin_conn: conn,
    notifications: notifications
  } do
    for notification <- notifications do
      Notifications.add(notification)
    end

    Notifications.clear_at(0)
    Notifications.clear_at(1)

    {:ok, _view, html} = live_isolated(conn, FzHttpWeb.NotificationsLive.Badge)

    assert html =~ "<span class=\"icon has-text-danger\"><i class=\"mdi mdi-circle\"></i>3</span>"
  end

  test "badge has 0 notifications after clearing all", %{
    admin_conn: conn,
    notifications: notifications
  } do
    for notification <- notifications do
      Notifications.add(notification)
    end

    Notifications.clear()

    {:ok, _view, html} = live_isolated(conn, FzHttpWeb.NotificationsLive.Badge)

    assert html =~
             "<span class=\"icon has-text-grey-dark\"><i class=\"mdi mdi-circle-outline\"></i></span>"
  end
end
