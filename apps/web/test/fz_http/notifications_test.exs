defmodule FzHttp.NotificationsTest do
  use FzHttp.DataCase, async: true
  import FzHttp.TestHelpers
  alias FzHttp.Notifications

  setup do
    {:ok, test_pid: start_supervised!(Notifications)}
  end

  setup [:create_notification, :create_notifications]

  test "add notification", %{test_pid: pid, notification: notification} do
    Notifications.add(pid, notification)

    assert [notification] == Notifications.current(pid)
  end

  test "clear notification", %{test_pid: pid, notification: notification} do
    Notifications.add(pid, notification)
    Notifications.clear(pid, notification)

    assert [] == Notifications.current(pid)
  end

  test "add multiple notifications", %{test_pid: pid, notifications: notifications} do
    for notification <- notifications do
      Notifications.add(pid, notification)
    end

    assert Enum.reverse(notifications) == Notifications.current(pid)
  end

  test "clear all notifications", %{test_pid: pid, notifications: notifications} do
    for notification <- notifications do
      Notifications.add(pid, notification)
    end

    Notifications.clear_all(pid)

    assert [] == Notifications.current(pid)
  end

  test "clear notification at index", %{test_pid: pid, notifications: notifications} do
    for notification <- notifications do
      Notifications.add(pid, notification)
    end

    Notifications.clear_at(pid, 2)

    {_, expected_notifications} = List.pop_at(notifications, 2)

    assert Enum.reverse(expected_notifications) == Notifications.current(pid)
  end
end
