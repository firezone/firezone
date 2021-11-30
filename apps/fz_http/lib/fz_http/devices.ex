defmodule FzHttp.Devices do
  @moduledoc """
  The Devices context.
  """

  import Ecto.Query, warn: false
  alias FzCommon.NameGenerator
  alias FzHttp.{ConnectivityChecks, Devices.Device, Repo, Settings, Users.User}

  @ipv4_prefix "10.3.2."
  @ipv6_prefix "fd00:3:2::"

  def list_devices do
    Repo.all(Device)
  end

  def list_devices(%User{} = user), do: list_devices(user.id)

  def list_devices(user_id) do
    Repo.all(from d in Device, where: d.user_id == ^user_id)
  end

  def get_device!(id), do: Repo.get!(Device, id)

  def create_device(attrs \\ %{}) do
    %Device{}
    |> Device.create_changeset(attrs)
    |> Repo.insert()
  end

  def update_device(%Device{} = device, attrs) do
    device
    |> Device.update_changeset(attrs)
    |> Repo.update()
  end

  def delete_device(%Device{} = device) do
    Repo.delete(device)
  end

  def change_device(%Device{} = device, attrs \\ %{}) do
    Device.update_changeset(device, attrs)
  end

  def rand_name do
    NameGenerator.generate()
  end

  def ipv4_address(%Device{} = device) do
    @ipv4_prefix <> Integer.to_string(device.address)
  end

  def ipv6_address(%Device{} = device) do
    @ipv6_prefix <> Integer.to_string(device.address)
  end

  def to_peer_list do
    for device <- Repo.all(Device) do
      %{
        public_key: device.public_key,
        allowed_ips: "#{ipv4_address(device)}/32,#{ipv6_address(device)}/128"
      }
    end
  end

  def allowed_ips(device) do
    if device.use_default_allowed_ips do
      Settings.default_device_allowed_ips()
    else
      device.allowed_ips
    end
  end

  def dns_servers(device) do
    if device.use_default_dns_servers do
      Settings.default_device_dns_servers()
    else
      device.dns_servers
    end
  end

  def endpoint(device) do
    if device.use_default_endpoint do
      Settings.default_device_endpoint() || ConnectivityChecks.endpoint()
    else
      device.endpoint
    end
  end

  def defaults(changeset) do
    ~w(use_default_allowed_ips use_default_dns_servers use_default_endpoint)a
    |> Enum.map(fn field -> {field, Device.field(changeset, field)} end)
    |> Map.new()
  end
end
