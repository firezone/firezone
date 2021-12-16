defmodule FzHttp.Devices do
  @moduledoc """
  The Devices context.
  """

  import Ecto.Query, warn: false
  alias FzCommon.{FzCrypto, NameGenerator}
  alias FzHttp.{ConnectivityChecks, Devices.Device, Repo, Settings, Users.User}

  @ipv4_prefix "10.3.2."
  @ipv6_prefix "fd00:3:2::"

  # Device configs can be viewable for 10 minutes
  @config_token_expires_in_sec 600

  def list_devices do
    Repo.all(Device)
  end

  def list_devices(%User{} = user), do: list_devices(user.id)

  def list_devices(user_id) do
    Repo.all(from d in Device, where: d.user_id == ^user_id)
  end

  def count(user_id) do
    Repo.one(from d in Device, where: d.user_id == ^user_id, select: count())
  end

  def get_device!(config_token: config_token) do
    now = DateTime.utc_now()

    Repo.one!(
      from d in Device,
        where: d.config_token == ^config_token and d.config_token_expires_at > ^now
    )
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

  def as_config(device) do
    wireguard_port = Application.fetch_env!(:fz_vpn, :wireguard_port)

    """
    [Interface]
    PrivateKey = #{device.private_key}
    Address = #{ipv4_address(device)}/32, #{ipv6_address(device)}/128
    #{dns_servers_config(device)}

    [Peer]
    PublicKey = #{device.server_public_key}
    AllowedIPs = #{allowed_ips(device)}
    Endpoint = #{endpoint(device)}:#{wireguard_port}
    """
  end

  def create_config_token(device) do
    expires_at = DateTime.add(DateTime.utc_now(), @config_token_expires_in_sec, :second)

    config_token_attrs = %{
      config_token: FzCrypto.rand_token(6),
      config_token_expires_at: expires_at
    }

    update_device(device, config_token_attrs)
  end

  defp dns_servers_config(device) when is_struct(device) do
    dns_servers = dns_servers(device)

    if dns_servers_empty?(dns_servers) do
      ""
    else
      "DNS = #{dns_servers}"
    end
  end

  defp dns_servers_empty?(nil), do: true

  defp dns_servers_empty?(dns_servers) when is_binary(dns_servers) do
    len =
      dns_servers
      |> String.trim()
      |> String.length()

    len == 0
  end
end
