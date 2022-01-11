defmodule FzHttp.Devices do
  @moduledoc """
  The Devices context.
  """

  import Ecto.Query, warn: false
  alias FzCommon.{FzCrypto, NameGenerator}
  alias FzHttp.{ConnectivityChecks, Devices.Device, Repo, Settings, Users, Users.User}

  # Device configs can be viewable for 10 minutes
  @config_token_expires_in_sec 600

  @events_module Application.compile_env!(:fz_http, :events_module)

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
    # XXX: insert sometimes fails with deadlock errors, probably because
    # of the giant SELECT in queries/inet.ex. Find a way to do this more gracefully.
    {:ok, device} =
      Repo.transaction(fn ->
        %Device{}
        |> Device.create_changeset(attrs)
        |> Repo.insert()
      end)

    device
  end

  @doc """
  Creates device with fields populated from the VPN process.
  """
  def auto_create_device(attrs \\ %{}) do
    {:ok, privkey, pubkey, server_pubkey} = @events_module.create_device()

    attributes =
      Map.merge(
        %{
          private_key: privkey,
          public_key: pubkey,
          server_public_key: server_pubkey,
          name: rand_name()
        },
        attrs
      )

    create_device(attributes)
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

  @doc """
  Builds ipv4 / ipv6 config string for a device.
  """
  def inet(device) do
    ips =
      if ipv6?() do
        ["#{device.ipv6}/128"]
      else
        []
      end

    ips =
      if ipv4?() do
        ["#{device.ipv4}/32" | ips]
      else
        ips
      end

    Enum.join(ips, ",")
  end

  def to_peer_list do
    vpn_duration = Settings.vpn_duration()

    Repo.all(
      from d in Device,
        preload: :user
    )
    |> Enum.filter(fn device ->
      device.user.role == :admin || !Users.vpn_session_expired?(device.user, vpn_duration)
    end)
    |> Enum.map(fn device ->
      %{
        public_key: device.public_key,
        inet: inet(device)
      }
    end)
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

  def new_device do
    change_device(%Device{})
  end

  def endpoint(device) do
    if device.use_default_endpoint do
      Settings.default_device_endpoint() || ConnectivityChecks.endpoint()
    else
      device.endpoint
    end
  end

  def mtu(device) do
    if device.use_default_mtu do
      Settings.default_device_mtu()
    else
      device.mtu
    end
  end

  def persistent_keepalives(device) do
    if device.use_default_persistent_keepalives do
      Settings.default_device_persistent_keepalives()
    else
      device.persistent_keepalives
    end
  end

  def defaults(changeset) do
    ~w(
      use_default_allowed_ips
      use_default_dns_servers
      use_default_endpoint
      use_default_mtu
      use_default_persistent_keepalives
    )a
    |> Enum.map(fn field -> {field, Device.field(changeset, field)} end)
    |> Map.new()
  end

  def as_config(device) do
    wireguard_port = Application.fetch_env!(:fz_vpn, :wireguard_port)

    """
    [Interface]
    PrivateKey = #{device.private_key}
    Address = #{inet(device)}
    #{mtu_config(device)}
    #{dns_servers_config(device)}

    [Peer]
    PublicKey = #{device.server_public_key}
    AllowedIPs = #{allowed_ips(device)}
    Endpoint = #{endpoint(device)}:#{wireguard_port}
    #{persistent_keepalives_config(device)}
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

  defp mtu_config(device) do
    m = mtu(device)

    if is_nil(m) do
      ""
    else
      "MTU = #{m}"
    end
  end

  defp persistent_keepalives_config(device) do
    pk = persistent_keepalives(device)

    if is_nil(pk) do
      ""
    else
      "PersistentKeepalive = #{pk}"
    end
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

  defp ipv4? do
    Application.fetch_env!(:fz_http, :wireguard_ipv4_enabled)
  end

  defp ipv6? do
    Application.fetch_env!(:fz_http, :wireguard_ipv6_enabled)
  end
end
