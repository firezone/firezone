defmodule FzHttpWeb.NotificationsLive.IndexTest do
  @moduledoc """
  Test adding and removing notifications from the notifications table.
  """
  use FzHttpWeb.ConnCase, async: false
  alias FzHttp.Notifications

  setup do
    {:ok, test_pid: start_supervised!(Notifications)}
  end

  setup [:create_notification, :create_notifications]

  test "add notification to the table", %{
    test_pid: pid,
    admin_conn: conn,
    notification: notification
  } do
    path = Routes.notifications_index_path(conn, :index)

    {:ok, _view, html} = live(conn, path)

    Notifications.add(pid, notification)

    assert html =~ notification.user
  end

  test "clear notification from the table", %{
    test_pid: pid,
    admin_conn: conn,
    notification: notification
  } do
    path = Routes.notifications_index_path(conn, :index)
    Notifications.add(pid, notification)
    {:ok, view, _html} = live(conn, path)

    view
    |> element(".delete")
    |> render_click()

    html =
      view
      |> render()

    refute html =~ notification.user
  end

  test "clear notification from the table at index", %{
    admin_conn: conn,
    test_pid: pid,
    notifications: notifications
  } do
    for notification <- notifications do
      Notifications.add(pid, notification)
    end

    path = Routes.notifications_index_path(conn, :index)
    {:ok, view, _html} = live(conn, path)

    index = 2
    {notification, _} = List.pop_at(notifications, index)

    view
    |> element(".delete[phx-value-index=#{index}")
    |> render_click()

    html =
      view
      |> render()

    refute html =~ notification.user
  end
end
