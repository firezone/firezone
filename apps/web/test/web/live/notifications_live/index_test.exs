defmodule Web.NotificationsLive.IndexTest do
  @moduledoc """
  Test adding and removing notifications from the notifications table.
  """
  use Web.ConnCase, async: false
  alias Domain.Notifications

  setup tags do
    # Pass the pid to the Notifications views
    pid = start_supervised!(Notifications)
    conn = put_session(tags[:admin_conn], :notifications_pid, pid)
    {:ok, test_pid: pid, admin_conn: conn}
  end

  setup [:create_notification, :create_notifications]

  test "add notification to the table", %{
    test_pid: pid,
    admin_conn: conn,
    notification: notification
  } do
    path = ~p"/notifications"
    Notifications.add(pid, notification)

    {:ok, _view, html} = live(conn, path)

    assert html =~ notification.user
  end

  test "clear notification from the table", %{
    test_pid: pid,
    admin_conn: conn,
    notification: notification
  } do
    path = ~p"/notifications"
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

    path = ~p"/notifications"
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
