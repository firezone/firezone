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
      public_key: public_key(),
      name: "factory #{counter()}",
      description: "factory description"
    }

    {:ok, device} = Devices.create_device(Map.merge(default_attrs, attrs))
    device
  end

  def public_key do
    :crypto.strong_rand_bytes(32)
    |> Base.encode64()
  end

  defp counter do
    System.unique_integer([:positive])
  end
end
