defmodule FzHttpWeb.NotificationsLive.BadgeTest do
  @moduledoc """
  Test notifications badge.
  """
  # async: true causes intermittent failures...
  use FzHttpWeb.ConnCase, async: false
  alias FzHttp.Notifications

  setup tags do
    # Pass the pid to the Notifications views
    pid = start_supervised!(Notifications)
    conn = put_session(tags[:admin_conn], :notifications_pid, pid)
    {:ok, test_pid: pid, admin_conn: conn}
  end

  setup [:create_notifications]

  test "badge has no notifications", %{admin_conn: conn} do
    {:ok, _view, html} = live_isolated(conn, FzHttpWeb.NotificationsLive.Badge)

    assert html =~
             "<span class=\"icon has-text-grey-dark\"><i class=\"mdi mdi-circle-outline\"></i></span>"
  end

  test "badge has 5 notifications after adding 5", %{
    admin_conn: conn,
    test_pid: pid,
    notifications: notifications
  } do
    for notification <- notifications do
      Notifications.add(pid, notification)
    end

    {:ok, _view, html} = live_isolated(conn, FzHttpWeb.NotificationsLive.Badge)

    assert html =~ "<span class=\"icon has-text-danger\"><i class=\"mdi mdi-circle\"></i>5</span>"
  end

  test "badge has 3 notifications after adding 5 and clearing 2", %{
    admin_conn: conn,
    test_pid: pid,
    notifications: notifications
  } do
    for notification <- notifications do
      Notifications.add(pid, notification)
    end

    Notifications.clear_at(pid, 0)
    Notifications.clear_at(pid, 1)

    {:ok, _view, html} = live_isolated(conn, FzHttpWeb.NotificationsLive.Badge)

    assert html =~ "<span class=\"icon has-text-danger\"><i class=\"mdi mdi-circle\"></i>3</span>"
  end

  test "badge has 0 notifications after clearing all", %{
    admin_conn: conn,
    test_pid: pid,
    notifications: notifications
  } do
    for notification <- notifications do
      Notifications.add(pid, notification)
    end

    Notifications.clear_all(pid)

    {:ok, _view, html} = live_isolated(conn, FzHttpWeb.NotificationsLive.Badge)

    assert html =~
             "<span class=\"icon has-text-grey-dark\"><i class=\"mdi mdi-circle-outline\"></i></span>"
  end
end
