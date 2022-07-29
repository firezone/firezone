defmodule FzHttpWeb.NotificationsLive.IndexTest do
  @moduledoc """
  Test adding and removing notifications from the notifications table.
  """
  use FzHttpWeb.ConnCase, async: true
  alias FzHttp.Notifications

  setup do
    start_supervised!(Notifications)
    :ok
  end

  setup [:create_notification, :create_notifications]

  test "add notification to the table", %{admin_conn: conn, notification: notification} do
    path = Routes.notifications_index_path(conn, :index)
    {:ok, view, _html} = live(conn, path)

    Notifications.add(notification)

    html =
      view
      |> render()

    assert html =~ notification.user
  end

  test "clear notification from the table", %{admin_conn: conn, notification: notification} do
    path = Routes.notifications_index_path(conn, :index)
    {:ok, view, _html} = live(conn, path)

    Notifications.add(notification)

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
    notifications: notifications
  } do
    path = Routes.notifications_index_path(conn, :index)
    {:ok, view, _html} = live(conn, path)

    for notification <- notifications do
      Notifications.add(notification)
    end

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
