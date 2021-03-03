defmodule FgHttp.Devices do
  @moduledoc """
  The Devices context.
  """

  import Ecto.Query, warn: false
  alias FgHttp.{Devices.Device, Repo}

  def list_devices do
    Repo.all(Device)
  end

  def list_devices(user_id) do
    Repo.all(from d in Device, where: d.user_id == ^user_id)
  end

  def list_devices(user_id, with_rules: true) do
    Repo.all(
      from d in Device,
        where: d.user_id == ^user_id,
        preload: :rules
    )
  end

  def get_device!(id), do: Repo.get!(Device, id)

  def get_device!(id, with_rules: true) do
    Repo.one(
      from d in Device,
        where: d.id == ^id,
        preload: :rules
    )
  end

  def create_device(attrs \\ %{}) do
    %Device{}
    |> Device.changeset(attrs)
    |> Repo.insert()
  end

  def update_device(%Device{} = device, attrs) do
    device
    |> Device.changeset(attrs)
    |> Repo.update()
  end

  def delete_device(%Device{} = device) do
    Repo.delete(device)
  end

  def change_device(%Device{} = device) do
    Device.changeset(device, %{})
  end

  def to_peer_list do
    for device <- Repo.all(Device) do
      %{
        public_key: device.public_key,
        allowed_ips: device.allowed_ips,
        preshared_key: device.preshared_key
      }
    end
  end
end
