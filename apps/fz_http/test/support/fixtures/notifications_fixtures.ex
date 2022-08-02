defmodule FzHttp.NotificationsFixtures do
  @moduledoc """
  This module defines test helpers for creating notifications.
  """

  @doc """
  Generate a notification.
  """
  def notification_fixture(attrs \\ []) do
    Enum.into(attrs, %{
      type: :error,
      user: "test@localhost",
      message: "Notification test text",
      timestamp: DateTime.utc_now()
    })
  end
end
