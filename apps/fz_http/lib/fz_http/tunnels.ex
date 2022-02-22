defmodule FzHttp.Tunnels do
  @moduledoc """
  The Tunnels context.
  """

  import Ecto.Query, warn: false
  alias FzCommon.NameGenerator
  alias FzHttp.{Repo, Sites, Telemetry, Tunnels.Tunnel, Users, Users.User}

  def list_tunnels do
    Repo.all(Tunnel)
  end

  def list_tunnels(%User{} = user), do: list_tunnels(user.id)

  def list_tunnels(user_id) do
    Repo.all(from d in Tunnel, where: d.user_id == ^user_id)
  end

  def count(user_id) do
    Repo.one(from d in Tunnel, where: d.user_id == ^user_id, select: count())
  end

  def get_tunnel!(id), do: Repo.get!(Tunnel, id)

  def create_tunnel(attrs \\ %{}) do
    # XXX: insert sometimes fails with deadlock errors, probably because
    # of the giant SELECT in queries/inet.ex. Find a way to do this more gracefully.
    {:ok, result} =
      Repo.transaction(fn ->
        %Tunnel{}
        |> Tunnel.create_changeset(attrs)
        |> Repo.insert()
      end)

    case result do
      {:ok, tunnel} ->
        Telemetry.add_tunnel(tunnel)

      _ ->
        nil
    end

    result
  end

  def update_tunnel(%Tunnel{} = tunnel, attrs) do
    tunnel
    |> Tunnel.update_changeset(attrs)
    |> Repo.update()
  end

  def delete_tunnel(%Tunnel{} = tunnel) do
    Telemetry.delete_tunnel(tunnel)
    Repo.delete(tunnel)
  end

  def change_tunnel(%Tunnel{} = tunnel, attrs \\ %{}) do
    Tunnel.update_changeset(tunnel, attrs)
  end

  @doc """
  Builds ipv4 / ipv6 config string for a tunnel.
  """
  def inet(tunnel) do
    ips =
      if ipv6?() do
        ["#{tunnel.ipv6}/128"]
      else
        []
      end

    ips =
      if ipv4?() do
        ["#{tunnel.ipv4}/32" | ips]
      else
        ips
      end

    Enum.join(ips, ",")
  end

  def to_peer_list do
    vpn_duration = Sites.vpn_duration()

    Repo.all(
      from d in Tunnel,
        preload: :user
    )
    |> Enum.filter(fn tunnel ->
      tunnel.user.role == :admin || !Users.vpn_session_expired?(tunnel.user, vpn_duration)
    end)
    |> Enum.map(fn tunnel ->
      %{
        public_key: tunnel.public_key,
        inet: inet(tunnel)
      }
    end)
  end

  def new_tunnel(attrs \\ %{}) do
    change_tunnel(%Tunnel{}, Map.merge(%{"name" => NameGenerator.generate()}, attrs))
  end

  def allowed_ips(tunnel), do: config(tunnel, :allowed_ips)
  def endpoint(tunnel), do: config(tunnel, :endpoint)
  def dns(tunnel), do: config(tunnel, :dns)
  def mtu(tunnel), do: config(tunnel, :mtu)
  def persistent_keepalive(tunnel), do: config(tunnel, :persistent_keepalive)

  defp config(tunnel, key) do
    if Map.get(tunnel, String.to_atom("use_site_#{key}")) do
      Map.get(Sites.wireguard_defaults(), key)
    else
      Map.get(tunnel, key)
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
    |> Enum.map(fn field -> {field, Tunnel.field(changeset, field)} end)
    |> Map.new()
  end

  def as_config(tunnel) do
    wireguard_port = Application.fetch_env!(:fz_vpn, :wireguard_port)
    server_public_key = Application.fetch_env!(:fz_vpn, :wireguard_public_key)

    """
    [Interface]
    PrivateKey = REPLACE_ME
    Address = #{inet(tunnel)}
    #{mtu_config(tunnel)}
    #{dns_config(tunnel)}

    [Peer]
    PublicKey = #{server_public_key}
    #{allowed_ips_config(tunnel)}
    Endpoint = #{endpoint(tunnel)}:#{wireguard_port}
    #{persistent_keepalive_config(tunnel)}
    """
  end

  defp mtu_config(tunnel) do
    m = mtu(tunnel)

    if field_empty?(m) do
      ""
    else
      "MTU = #{m}"
    end
  end

  defp allowed_ips_config(tunnel) do
    a = allowed_ips(tunnel)

    if field_empty?(a) do
      ""
    else
      "AllowedIPs = #{a}"
    end
  end

  defp persistent_keepalive_config(tunnel) do
    pk = persistent_keepalive(tunnel)

    if field_empty?(pk) do
      ""
    else
      "PersistentKeepalive = #{pk}"
    end
  end

  defp dns_config(tunnel) when is_struct(tunnel) do
    dns = dns(tunnel)

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
