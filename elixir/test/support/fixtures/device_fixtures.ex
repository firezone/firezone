defmodule Portal.DeviceFixtures do
  @moduledoc """
  Helpers for working with device fixtures.
  """

  def valid_ipv4_address_attrs do
    offset = System.unique_integer([:positive, :monotonic])
    third = rem(div(offset, 256), 32)
    fourth = rem(offset, 256)
    fourth = if fourth < 2, do: fourth + 2, else: fourth

    %{
      address: %Postgrex.INET{address: {100, 64, third, fourth}}
    }
  end

  def valid_ipv6_address_attrs do
    offset = System.unique_integer([:positive, :monotonic])
    w7 = rem(div(offset, 65_536), 65_536)
    w8 = rem(offset, 65_536)
    w8 = if w8 < 2, do: w8 + 2, else: w8

    %{
      address: %Postgrex.INET{address: {64_768, 8_225, 4_369, 0, 0, 0, w7, w8}}
    }
  end

  def sync_device_ipv4(%Portal.Device{} = device, %Postgrex.INET{} = address) do
    Portal.Repo.update!(Ecto.Changeset.change(device, ipv4: address))
  end

  def sync_device_ipv6(%Portal.Device{} = device, %Postgrex.INET{} = address) do
    Portal.Repo.update!(Ecto.Changeset.change(device, ipv6: address))
  end

  @doc """
  Returns the device row used by channel and API tests.
  """
  def fetch_device!(%Portal.Device{} = device), do: device
end
