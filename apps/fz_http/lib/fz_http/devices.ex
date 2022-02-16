defmodule FzHttp.Devices do
  @moduledoc """
  The Devices context.
  """

  import Ecto.Query, warn: false
  alias FzCommon.NameGenerator
  alias FzHttp.{ConnectivityChecks, Devices.Device, Repo, Sites, Telemetry, Users, Users.User}

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

  def get_device!(id), do: Repo.get!(Device, id)

  def create_device(attrs \\ %{}) do
    # XXX: insert sometimes fails with deadlock errors, probably because
    # of the giant SELECT in queries/inet.ex. Find a way to do this more gracefully.
    {:ok, result} =
      Repo.transaction(fn ->
        %Device{}
        |> Device.create_changeset(attrs)
        |> Repo.insert()
      end)

    case result do
      {:ok, device} ->
        Telemetry.add_device(device)

      _ ->
        nil
    end

    result
  end

  def update_device(%Device{} = device, attrs) do
    device
    |> Device.update_changeset(attrs)
    |> Repo.update()
  end

  def delete_device(%Device{} = device) do
    Telemetry.delete_device(device)
    Repo.delete(device)
  end

  def change_device(%Device{} = device, attrs \\ %{}) do
    Device.update_changeset(device, attrs)
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
    vpn_duration = Sites.vpn_duration()

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

  def new_device(attrs \\ %{}) do
    change_device(%Device{}, Map.merge(%{name: NameGenerator.generate()}, attrs))
  end

  def endpoint(device) do
    if device.use_site_endpoint do
      Sites.get_site!().endpoint ||
        Application.fetch_env!(:fz_http, :wireguard_endpoint) ||
        ConnectivityChecks.endpoint()
    else
      device.endpoint
    end
  end

  def allowed_ips(device) do
    if device.use_site_allowed_ips do
      Sites.get_site!().allowed_ips ||
        Application.fetch_env!(:fz_http, :wireguard_allowed_ips)
    else
      device.allowed_ips
    end
  end

  def dns(device) do
    if device.use_site_dns do
      Sites.get_site!().dns ||
        Application.fetch_env!(:fz_http, :wireguard_dns)
    else
      device.dns
    end
  end

  def mtu(device) do
    if device.use_site_mtu do
      Sites.get_site!().mtu ||
        Application.fetch_env!(:fz_http, :wireguard_mtu)
    else
      device.mtu
    end
  end

  def persistent_keepalive(device) do
    if device.use_site_persistent_keepalive do
      Sites.get_site!().persistent_keepalive ||
        Application.fetch_env!(:fz_http, :wireguard_persistent_keepalive)
    else
      device.persistent_keepalive
    end
  end

  def defaults(changeset) do
    ~w(
      use_site_allowed_ips
      use_site_dns
      use_site_endpoint
      use_site_mtu
      use_site_persistent_keepalive
    )a
    |> Enum.map(fn field -> {field, Device.field(changeset, field)} end)
    |> Map.new()
  end

  def as_config(device) do
    wireguard_port = Application.fetch_env!(:fz_vpn, :wireguard_port)
    server_public_key = Application.fetch_env!(:fz_vpn, :wireguard_public_key)

    """
    [Interface]
    PrivateKey = REPLACE_ME
    Address = #{inet(device)}
    #{mtu_config(device)}
    #{dns_config(device)}

    [Peer]
    PublicKey = #{server_public_key}
    #{allowed_ips_config(device)}
    Endpoint = #{endpoint(device)}:#{wireguard_port}
    #{persistent_keepalive_config(device)}
    """
  end

  defp mtu_config(device) do
    m = mtu(device)

    if field_empty?(m) do
      ""
    else
      "MTU = #{m}"
    end
  end

  defp allowed_ips_config(device) do
    a = allowed_ips(device)

    if field_empty?(a) do
      ""
    else
      "AllowedIPs = #{a}"
    end
  end

  defp persistent_keepalive_config(device) do
    pk = persistent_keepalive(device)

    if field_empty?(pk) do
      ""
    else
      "PersistentKeepalive = #{pk}"
    end
  end

  defp dns_config(device) when is_struct(device) do
    dns = dns(device)

    if field_empty?(dns) do
      ""
    else
      "DNS = #{dns}"
    end
  end

  defp field_empty?(nil), do: true

  defp field_empty?(0), do: true

  defp field_empty?(field) when is_binary(field) do
    len =
      field
      |> String.trim()
      |> String.length()

    len == 0
  end

  defp field_empty?(_), do: false

  defp ipv4? do
    Application.fetch_env!(:fz_http, :wireguard_ipv4_enabled)
  end

  defp ipv6? do
    Application.fetch_env!(:fz_http, :wireguard_ipv6_enabled)
  end
end
