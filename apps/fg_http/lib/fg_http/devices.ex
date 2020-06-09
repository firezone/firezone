defmodule FgHttp.Devices do
  @moduledoc """
  The Devices context.
  """

  import Ecto.Query, warn: false
  alias FgHttp.Repo

  alias FgHttp.Devices.Device

  def list_devices(user_id) do
    Repo.all(from d in Device, where: d.user_id == ^user_id)
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
end
