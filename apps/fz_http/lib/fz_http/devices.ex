defmodule FzHttp.Devices do
  import Ecto.Changeset
  import Ecto.Query, warn: false
  alias EctoNetwork.INET
  alias FzHttp.{Configurations, Devices.Device, Repo, Telemetry, Users.User, Gateways, Events}

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
    |> Enum.map(&to_peer/1)
    |> MapSet.new()
  end

  def to_peer(%Device{} = device) do
    device = Repo.preload(device, :user)

    %{
      allowed_ips: inet(device),
      user_id: device.user.id,
      public_key: device.public_key,
      preshared_key: device.preshared_key
    }
  end

  def to_peer(device) do
    struct(Device, device) |> to_peer()
  end

  def get_device!(id), do: Repo.get!(Device, id)

  def create_device(attrs \\ %{}) do
    attrs
    |> Device.create_changeset()
    |> Repo.insert()
    |> case do
      {:ok, device} ->
        Events.add(device)
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

    with {:ok, device} <- Repo.delete(device) do
      Events.delete(device)
      {:ok, device}
    end
  end

  def change_device(%Device{} = device, attrs \\ %{}) do
    Device.update_changeset(device, attrs)
  end

  defp inet(device) do
    ips =
      if ipv6?() do
        ["#{device.ipv6}"]
      else
        []
      end

    ips =
      if ipv4?() do
        ["#{device.ipv4}" | ips]
      else
        ips
      end

    ips
  end

  def new_device(attrs \\ %{}) do
    change_device(%Device{}, attrs)
  end

  def allowed_ips(device), do: config(device, :allowed_ips)
  def endpoint(device), do: config(device, :endpoint)
  def dns(device), do: config(device, :dns)
  def mtu(device), do: config(device, :mtu)
  def persistent_keepalive(device), do: config(device, :persistent_keepalive)

  def config(device, key) do
    if Map.get(device, String.to_atom("use_default_#{key}")) do
      Map.get(Configurations.get_configuration!(), String.to_atom("default_client_#{key}"))
    else
      Map.get(device, key)
    end
  end

  def defaults(changeset) do
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
    server_public_key = Gateways.get_gateway!().public_key

    if is_nil(server_public_key) do
      Logger.error("No server public key found! This will break device config generation.")
    end

    """
    [Interface]
    PrivateKey = REPLACE_ME
    Address = #{inet(device) |> Enum.join(",")}
    #{mtu_config(device)}
    #{dns_config(device)}

    [Peer]
    #{psk_config(device)}
    PublicKey = #{server_public_key}
    #{allowed_ips_config(device)}
    #{endpoint_config(device)}
    #{persistent_keepalive_config(device)}
    """
  end

  def decode(nil), do: nil
  def decode(inet) when is_binary(inet), do: inet
  def decode(inet), do: INET.decode(inet)

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

  defp endpoint_config(device) do
    ep = endpoint(device)

    if field_empty?(ep) do
      ""
    else
      "Endpoint = #{maybe_add_port(ep)}"
    end
  end

  # Finds a port in IPv6-formatted address, e.g. [2001::1]:51820
  @capture_port ~r/\[.*]:(?<port>[\d]+)/
  defp maybe_add_port(endpoint) do
    wireguard_port = FzHttp.Config.fetch_env!(:fz_http, :default_wireguard_port)
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

  defp field_empty?(field) when is_binary(field) do
    len =
      field
      |> String.trim()
      |> String.length()

    len == 0
  end

  defp field_empty?(_), do: false

  defp ipv4? do
    FzHttp.Config.fetch_env!(:fz_http, :wireguard_ipv4_enabled)
  end

  defp ipv6? do
    FzHttp.Config.fetch_env!(:fz_http, :wireguard_ipv6_enabled)
  end
end
