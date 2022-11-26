defmodule FzHttp.DevicesFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `FzHttp.Devices` context.
  """

  alias FzHttp.{
    Devices,
    UsersFixtures
  }

  @doc """
  Generate a device.
  """
  def device(attrs \\ %{}) do
    # Don't create a user if user_id is passed
    user_id = Map.get_lazy(attrs, :user_id, fn -> UsersFixtures.user().id end)

    default_attrs = %{
      user_id: user_id,
      public_key: "test-pubkey",
      name: "factory",
      description: "factory description"
    }

    {:ok, device} = Devices.create_device(Map.merge(default_attrs, attrs))
    device
  end
end
