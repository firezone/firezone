defmodule FzHttp.Devices.Device.Changeset do
  use FzHttp, :changeset
  import FzHttp.Config, only: [config_changeset: 3]
  alias FzHttp.Users
  alias FzHttp.Devices

  @create_fields ~w[name description
                    public_key preshared_key]a

  @update_fields ~w[name description]a

  @configure_fields ~w[ipv4 ipv6
                       use_default_allowed_ips allowed_ips
                       use_default_dns dns
                       use_default_endpoint endpoint
                       use_default_mtu mtu
                       use_default_persistent_keepalive persistent_keepalive]a

  @metrics_fields ~w[remote_ip
                     latest_handshake
                     rx_bytes tx_bytes]a

  @required_fields ~w[name public_key]a

  # WireGuard base64-encoded string length
  @key_length 44

  def create_changeset(%Users.User{} = user, attrs) do
    create_changeset(attrs)
    |> put_change(:user_id, user.id)
  end

  def create_changeset(attrs) do
    %Devices.Device{}
    |> cast(attrs, @create_fields)
    |> put_default_value(:name, &FzHttp.Devices.generate_name/0)
    |> put_default_value(:preshared_key, &FzHttp.Crypto.psk/0)
    |> changeset()
    |> validate_base64(:public_key)
    |> validate_base64(:preshared_key)
    |> validate_length(:public_key, is: @key_length)
    |> validate_length(:preshared_key, is: @key_length)
    |> prepare_changes(fn changeset ->
      changeset
      |> maybe_put_default_ip(:ipv4)
      |> maybe_put_default_ip(:ipv6)
    end)
    |> unique_constraint(:ipv4)
    |> unique_constraint(:ipv6)
    |> unique_constraint(:public_key)
    |> validate_max_devices()
    |> validate_required(@required_fields)
  end

  def configure_changeset(changeset, attrs) do
    changeset
    |> cast(attrs, @configure_fields)
    |> trim_change(:dns)
    |> trim_change(:endpoint)
    |> config_changeset(:allowed_ips, :default_client_allowed_ips)
    |> config_changeset(:dns, :default_client_dns)
    |> config_changeset(:endpoint, :default_client_endpoint)
    |> config_changeset(:persistent_keepalive, :default_client_persistent_keepalive)
    |> config_changeset(:mtu, :default_client_mtu)
    |> validate_required_unless_default([:endpoint])
    |> validate_omitted_if_default(~w[
      allowed_ips
      dns
      endpoint
      persistent_keepalive
      mtu
    ]a)
    |> validate_exclusion(:ipv4, [ipv4_address()])
    |> validate_exclusion(:ipv6, [ipv6_address()])
    |> validate_in_cidr(:ipv4, wireguard_network(:ipv4))
    |> validate_in_cidr(:ipv6, wireguard_network(:ipv6))
  end

  def update_changeset(device, attrs) do
    device
    |> cast(attrs, @update_fields)
    |> changeset()
    |> validate_required(@required_fields)
  end

  def metrics_changeset(device, attrs) do
    device
    |> cast(attrs, @metrics_fields)
  end

  defp changeset(changeset) do
    changeset
    |> trim_change(:name)
    |> trim_change(:description)
    |> validate_length(:description, max: 2048)
    |> validate_length(:name, min: 1, max: 255)
    |> assoc_constraint(:user)
    |> unique_constraint([:user_id, :name])
  end

  defp maybe_put_default_ip(changeset, field) do
    if FzHttp.Config.fetch_env!(:fz_http, :"wireguard_#{field}_enabled") == true do
      case fetch_field(changeset, field) do
        {:data, nil} -> put_default_ip(changeset, field)
        :error -> put_default_ip(changeset, field)
        _ -> changeset
      end
      |> validate_required(field)
    else
      changeset
    end
  end

  defp put_default_ip(changeset, field) do
    cidr = wireguard_network(field)
    hosts = FzHttp.Types.CIDR.count_hosts(cidr)
    offset = Enum.random(2..(hosts - 2))

    {:ok, gateway_address} =
      FzHttp.Config.fetch_env!(:fz_http, :"wireguard_#{field}_address")
      |> FzHttp.Types.IP.cast()

    Devices.Device.Query.next_available_address(cidr, offset, [gateway_address])
    |> FzHttp.Repo.one()
    |> case do
      nil -> add_error(changeset, :base, "CIDR #{cidr} is exhausted")
      ip -> put_change(changeset, field, ip)
    end
  end

  defp wireguard_network(field) do
    cidr = FzHttp.Config.fetch_env!(:fz_http, :"wireguard_#{field}_network")
    %{cidr | netmask: limit_cidr_netmask(field, cidr.netmask)}
  end

  defp limit_cidr_netmask(:ipv4, network), do: network
  defp limit_cidr_netmask(:ipv6, network), do: max(network, 70)

  defp ipv4_address do
    FzHttp.Config.fetch_env!(:fz_http, :wireguard_ipv4_address)
    |> FzHttp.Types.IP.cast()
  end

  defp ipv6_address do
    FzHttp.Config.fetch_env!(:fz_http, :wireguard_ipv6_address)
    |> FzHttp.Types.IP.cast()
  end

  defp validate_max_devices(changeset) do
    # XXX: This suffers from a race condition because the count happens in a separate transaction.
    # At the moment it's not a big concern. Fixing it would require locking against INSERTs or DELETEs
    # while counts are happening.
    count =
      case get_field(changeset, :user_id) do
        nil -> 0
        user_id -> Devices.count_by_user_id(user_id)
      end

    max_devices = FzHttp.Config.fetch_env!(:fz_http, :max_devices_per_user)

    if count >= max_devices do
      add_error(
        changeset,
        :base,
        "Maximum device limit reached. Remove an existing device before creating a new one."
      )
    else
      changeset
    end
  end

  defp validate_omitted_if_default(changeset, fields) when is_list(fields) do
    validate_omitted(
      changeset,
      filter_default_fields(changeset, fields, use_default: true)
    )
  end

  defp validate_required_unless_default(changeset, fields) when is_list(fields) do
    validate_required(changeset, filter_default_fields(changeset, fields, use_default: false))
  end

  defp filter_default_fields(changeset, fields, use_default: use_default)
       when is_boolean(use_default) do
    fields
    |> Enum.map(fn field -> String.to_atom("use_default_#{field}") end)
    |> Enum.filter(fn default_field -> get_field(changeset, default_field) == use_default end)
    |> Enum.map(fn field ->
      field
      |> Atom.to_string()
      |> String.trim("use_default_")
      |> String.to_atom()
    end)
  end
end
