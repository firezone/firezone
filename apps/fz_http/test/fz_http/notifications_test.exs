defmodule FzHttp.NotificationsTest do
  use FzHttp.DataCase, async: true
  alias FzHttp.Notifications

  setup do
    start_supervised!(Notifications)
    :ok
  end

  setup [:create_notification, :create_notifications]

  test "add notification", %{notification: notification} do
    Notifications.add(notification)

    assert [notification] == Notifications.current()
  end

  test "clear notification", %{notification: notification} do
    Notifications.add(notification)
    Notifications.clear(notification)

    assert [] == Notifications.current()
  end

  test "add multiple notifications", %{notifications: notifications} do
    for notification <- notifications do
      Notifications.add(notification)
    end

    assert notifications |> Enum.reverse() == Notifications.current()
  end

  test "clear all notifications", %{notifications: notifications} do
    for notification <- notifications do
      Notifications.add(notification)
    end

    Notifications.clear()

    assert [] == Notifications.current()
  end

  test "clear notification at index", %{notifications: notifications} do
    for notification <- notifications do
      Notifications.add(notification)
    end

    Notifications.clear_at(2)

    {_, expected_notifications} = List.pop_at(notifications, 2)

    assert expected_notifications |> Enum.reverse() == Notifications.current()
  end
end
