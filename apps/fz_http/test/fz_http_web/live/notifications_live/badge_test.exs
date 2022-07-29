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
    {:ok, view, _html} = live_isolated(conn, FzHttpWeb.NotificationsLive.Badge)

    html =
      view
      |> render()

    assert html =~
             "<span class=\"icon has-text-grey-dark\"><i class=\"mdi mdi-circle-outline\"></i></span>"
  end

  test "badge has 5 notifications after adding 5", %{
    admin_conn: conn,
    notifications: notifications
  } do
    {:ok, view, _html} = live_isolated(conn, FzHttpWeb.NotificationsLive.Badge)

    for notification <- notifications do
      Notifications.add(notification)
    end

    html =
      view
      |> render()

    assert html =~ "<span class=\"icon has-text-danger\"><i class=\"mdi mdi-circle\"></i>5</span>"
  end

  test "badge has 3 notifications after adding 5 and clearing 2", %{
    admin_conn: conn,
    notifications: notifications
  } do
    {:ok, view, _html} = live_isolated(conn, FzHttpWeb.NotificationsLive.Badge)

    for notification <- notifications do
      Notifications.add(notification)
    end

    Notifications.clear_at(0)
    Notifications.clear_at(1)

    html =
      view
      |> render()

    assert html =~ "<span class=\"icon has-text-danger\"><i class=\"mdi mdi-circle\"></i>3</span>"
  end

  test "badge has 0 notifications after clearing all", %{
    admin_conn: conn,
    notifications: notifications
  } do
    {:ok, view, _html} = live_isolated(conn, FzHttpWeb.NotificationsLive.Badge)

    for notification <- notifications do
      Notifications.add(notification)
    end

    Notifications.clear()

    html =
      view
      |> render()

    assert html =~
             "<span class=\"icon has-text-grey-dark\"><i class=\"mdi mdi-circle-outline\"></i></span>"
  end
end
