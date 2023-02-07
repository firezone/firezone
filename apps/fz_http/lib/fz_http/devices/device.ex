defmodule FzHttp.Devices.Device do
  @moduledoc """
  Manages Device things
  """
  use FzHttp, :schema
  import Ecto.Changeset
  alias FzHttp.Validator
  alias FzHttp.Devices
  require Logger

  @description_max_length 2048

  # WireGuard base64-encoded string length
  @key_length 44

  schema "devices" do
    field :rx_bytes, :integer
    field :tx_bytes, :integer
    field :name, :string
    field :description, :string
    field :public_key, :string
    field :preshared_key, FzHttp.Encrypted.Binary
    field :use_default_allowed_ips, :boolean, read_after_writes: true, default: true
    field :use_default_dns, :boolean, read_after_writes: true, default: true
    field :use_default_endpoint, :boolean, read_after_writes: true, default: true
    field :use_default_mtu, :boolean, read_after_writes: true, default: true
    field :use_default_persistent_keepalive, :boolean, read_after_writes: true, default: true
    field :endpoint, :string
    field :mtu, :integer
    field :persistent_keepalive, :integer
    field :allowed_ips, {:array, FzHttp.Types.INET}, default: []
    field :dns, {:array, :string}, default: []
    field :remote_ip, FzHttp.Types.IP
    # TODO: make it a parametrized type and add ipv4/6 type parameter
    field :ipv4, FzHttp.Types.IP
    field :ipv6, FzHttp.Types.IP

    field :latest_handshake, :utc_datetime_usec
    field :key_regenerated_at, :utc_datetime_usec, read_after_writes: true

    belongs_to :user, FzHttp.Users.User

    timestamps()
  end

  @fields ~w[
      latest_handshake
      rx_bytes
      tx_bytes
      use_default_allowed_ips
      use_default_dns
      use_default_endpoint
      use_default_mtu
      use_default_persistent_keepalive
      allowed_ips
      dns
      endpoint
      mtu
      persistent_keepalive
      remote_ip
      ipv4
      ipv6
      user_id
      name
      description
      public_key
      preshared_key
      key_regenerated_at
    ]a

  @required_fields ~w[user_id name public_key]a

  def create_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, @fields)
    |> Validator.put_default_value(:name, &FzHttp.Devices.new_name/0)
    |> Validator.put_default_value(:preshared_key, &FzCommon.FzCrypto.psk/0)
    |> changeset()
    |> validate_max_devices()
    |> validate_required(@required_fields)
  end

  def update_changeset(device, attrs) do
    device
    |> cast(attrs, @fields)
    |> changeset()
    |> validate_required(@required_fields)
  end

  defp changeset(changeset) do
    changeset
    |> Validator.trim_change(:dns)
    |> Validator.trim_change(:endpoint)
    |> Validator.trim_change(:name)
    |> Validator.trim_change(:description)
    |> Validator.validate_base64(:public_key)
    |> Validator.validate_base64(:preshared_key)
    |> validate_length(:public_key, is: @key_length)
    |> validate_length(:preshared_key, is: @key_length)
    |> validate_length(:description, max: @description_max_length)
    |> validate_length(:name, min: 1)
    |> assoc_constraint(:user)
    |> validate_required_unless_default([:endpoint])
    |> validate_omitted_if_default(~w[
      allowed_ips
      dns
      endpoint
      persistent_keepalive
      mtu
    ]a)
    |> Validator.validate_no_duplicates(:dns)
    |> validate_number(:persistent_keepalive,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: 120
    )
    |> validate_number(:mtu,
      greater_than_or_equal_to: 576,
      less_than_or_equal_to: 1500
    )
    |> prepare_changes(fn changeset ->
      changeset
      |> maybe_put_default_ip(:ipv4)
      |> maybe_put_default_ip(:ipv6)
      |> validate_exclusion(:ipv4, [ipv4_address()])
      |> validate_exclusion(:ipv6, [ipv6_address()])
    end)
    |> unique_constraint(:ipv4)
    |> unique_constraint(:ipv6)
    |> unique_constraint(:public_key)
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
    cidr_string = wireguard_network(field)
    {:ok, cidr_inet} = FzHttp.Types.CIDR.cast(cidr_string)
    cidr = CIDR.parse(cidr_string)
    offset = Enum.random(2..(cidr.hosts - 2))

    {:ok, gateway_address} =
      FzHttp.Config.fetch_env!(:fz_http, :"wireguard_#{field}_address")
      |> FzHttp.Types.IP.cast()

    Devices.Device.Query.next_available_address(cidr_inet, offset, [gateway_address])
    |> FzHttp.Repo.one()
    |> case do
      nil -> add_error(changeset, :base, "CIDR #{cidr} is exhausted")
      ip -> put_change(changeset, field, ip)
    end
  end

  defp wireguard_network(field) do
    cidr_string = FzHttp.Config.fetch_env!(:fz_http, :"wireguard_#{field}_network")
    [inet, network] = String.split(cidr_string, "/")
    network = String.to_integer(network)
    "#{inet}/#{limit_cidr_range(field, network)}"
  end

  defp limit_cidr_range(:ipv4, network), do: network
  defp limit_cidr_range(:ipv6, network), do: max(network, 70)

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
      get_field(changeset, :user_id)
      |> Devices.count()

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
    Validator.validate_omitted(
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
