defmodule FzHttp.Devices do
  import Ecto.Changeset
  import Ecto.Query, warn: false

  alias FzHttp.{
    Config,
    Devices.Device,
    Devices.DeviceSetting,
    Repo,
    Telemetry,
    Users,
    Users.User
  }

  require Logger

  def count_active_within(duration_in_secs) when is_integer(duration_in_secs) do
    cutoff = DateTime.add(DateTime.utc_now(), -1 * duration_in_secs)

    Repo.one(
      from d in Device,
        select: count(d.id),
        where: d.latest_handshake > ^cutoff
    )
  end

  def count do
    Repo.aggregate(Device, :count)
  end

  def count(nil), do: 0

  def count(user_id) do
    Repo.one(from d in Device, where: d.user_id == ^user_id, select: count())
  end

  def max_count_by_user_id do
    Repo.one(
      from d in Device,
        select: fragment("count(*) AS user_count"),
        group_by: d.user_id,
        order_by: fragment("user_count DESC"),
        limit: 1
    )
  end

  def list_devices do
    Repo.all(Device)
  end

  def list_devices(%User{} = user), do: list_devices(user.id)

  def list_devices(user_id) do
    Repo.all(from d in Device, where: d.user_id == ^user_id)
  end

  def as_settings do
    Repo.all(from(Device))
    |> Enum.map(&setting_projection/1)
    |> MapSet.new()
  end

  def setting_projection(device) do
    device
    |> DeviceSetting.parse()
    |> Map.from_struct()
  end

  def get_device!(id), do: Repo.get!(Device, id)

  def create_device(attrs \\ %{}) do
    attrs
    |> Device.create_changeset()
    |> Repo.insert()
    |> case do
      {:ok, device} ->
        Telemetry.add_device()
        {:ok, device}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  def update_device(%Device{} = device, attrs) do
    device
    |> Device.update_changeset(attrs)
    |> Repo.update()
  end

  def delete_device(%Device{} = device) do
    Telemetry.delete_device()
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
    Repo.all(
      from d in Device,
        preload: :user
    )
    |> Enum.filter(fn device ->
      !device.user.disabled_at && !Users.vpn_session_expired?(device.user)
    end)
    |> Enum.map(fn device ->
      %{
        public_key: device.public_key,
        inet: inet(device),
        preshared_key: device.preshared_key
      }
    end)
  end

  def new_device(attrs \\ %{}) do
    change_device(%Device{}, attrs)
  end

  def allowed_ips(device, defaults), do: config(device, defaults, :allowed_ips)
  def endpoint(device, defaults), do: config(device, defaults, :endpoint)
  def dns(device, defaults), do: config(device, defaults, :dns)
  def mtu(device, defaults), do: config(device, defaults, :mtu)
  def persistent_keepalive(device, defaults), do: config(device, defaults, :persistent_keepalive)

  # XXX: This is an A* query which is executed for every config key,
  # we can load all configs in a batch instead
  def config(device, defaults, key) do
    if Map.get(device, String.to_atom("use_default_#{key}")) do
      Map.fetch!(defaults, String.to_atom("default_client_#{key}"))
    else
      Map.get(device, key)
    end
  end

  def defaults do
    Config.fetch_configs!([
      :default_client_allowed_ips,
      :default_client_endpoint,
      :default_client_dns,
      :default_client_mtu,
      :default_client_persistent_keepalive
    ])
  end

  def use_default_fields(changeset) do
    ~w(
      use_default_allowed_ips
      use_default_dns
      use_default_endpoint
      use_default_mtu
      use_default_persistent_keepalive
    )a
    |> Map.new(&{&1, get_field(changeset, &1)})
  end

  def as_encoded_config(device), do: Base.encode64(as_config(device))

  def as_config(device) do
    server_public_key = Application.get_env(:fz_vpn, :wireguard_public_key)
    defaults = defaults()

    if is_nil(server_public_key) do
      Logger.error(
        "No server public key found! This will break device config generation. Is fz_vpn alive?"
      )
    end

    """
    [Interface]
    PrivateKey = REPLACE_ME
    Address = #{inet(device)}
    #{mtu_config(device, defaults)}
    #{dns_config(device, defaults)}

    [Peer]
    #{psk_config(device)}
    PublicKey = #{server_public_key}
    #{allowed_ips_config(device, defaults)}
    #{endpoint_config(device, defaults)}
    #{persistent_keepalive_config(device, defaults)}
    """
  end

  def decode(nil), do: nil
  def decode(inet) when is_binary(inet), do: inet
  def decode(inet), do: FzHttp.Types.INET.to_string(inet)

  @hash_range 2 ** 16
  def new_name(name \\ FzCommon.NameGenerator.generate()) do
    hash =
      name
      |> :erlang.phash2(@hash_range)
      |> Integer.to_string(16)
      |> String.pad_leading(4, "0")

    if String.length(name) > 15 do
      String.slice(name, 0..10) <> hash
    else
      name
    end
  end

  defp psk_config(device) do
    if device.preshared_key do
      "PresharedKey = #{device.preshared_key}"
    else
      ""
    end
  end

  defp mtu_config(device, defaults) do
    m = mtu(device, defaults)

    if field_empty?(m) do
      ""
    else
      "MTU = #{m}"
    end
  end

  defp allowed_ips_config(device, defaults) do
    allowed_ips = allowed_ips(device, defaults)

    if field_empty?(allowed_ips) do
      ""
    else
      "AllowedIPs = #{Enum.join(allowed_ips, ",")}"
    end
  end

  defp persistent_keepalive_config(device, defaults) do
    pk = persistent_keepalive(device, defaults)

    if field_empty?(pk) do
      ""
    else
      "PersistentKeepalive = #{pk}"
    end
  end

  defp dns_config(device, defaults) when is_struct(device) do
    dns = dns(device, defaults)

    if field_empty?(dns) do
      ""
    else
      "DNS = #{Enum.join(dns, ",")}"
    end
  end

  defp endpoint_config(device, defaults) do
    ep = endpoint(device, defaults)

    if field_empty?(ep) do
      ""
    else
      "Endpoint = #{maybe_add_port(ep)}"
    end
  end

  # Finds a port in IPv6-formatted address, e.g. [2001::1]:51820
  @capture_port ~r/\[.*]:(?<port>[\d]+)/
  defp maybe_add_port(endpoint) do
    wireguard_port = Config.fetch_env!(:fz_vpn, :wireguard_port)
    colon_count = endpoint |> String.graphemes() |> Enum.count(&(&1 == ":"))

    if colon_count == 1 or !is_nil(Regex.named_captures(@capture_port, endpoint)) do
      endpoint
    else
      # No port found
      "#{endpoint}:#{wireguard_port}"
    end
  end

  defp field_empty?(nil), do: true
  defp field_empty?(0), do: true
  defp field_empty?([]), do: true

  defp field_empty?(field) when is_binary(field) do
    len =
      field
      |> String.trim()
      |> String.length()

    len == 0
  end

  defp field_empty?(_), do: false

  defp ipv4? do
    Config.fetch_env!(:fz_http, :wireguard_ipv4_enabled)
  end

  defp ipv6? do
    Config.fetch_env!(:fz_http, :wireguard_ipv6_enabled)
  end
end
