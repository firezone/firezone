defmodule FzHttp.Devices.Device do
  @moduledoc """
  Manages Device things
  """
  use Ecto.Schema
  import Ecto.Changeset
  alias FzHttp.Validators.Common
  alias FzHttp.{Devices, Users.User}
  require Logger

  @description_max_length 2048

  schema "devices" do
    field :rx_bytes, :integer
    field :tx_bytes, :integer
    field :uuid, Ecto.UUID, autogenerate: true
    field :name, :string
    field :description, :string
    field :public_key, :string
    field :preshared_key, FzHttp.Encrypted.Binary
    field :use_site_allowed_ips, :boolean, read_after_writes: true, default: true
    field :use_site_dns, :boolean, read_after_writes: true, default: true
    field :use_site_endpoint, :boolean, read_after_writes: true, default: true
    field :use_site_mtu, :boolean, read_after_writes: true, default: true
    field :use_site_persistent_keepalive, :boolean, read_after_writes: true, default: true
    field :endpoint, :string
    field :mtu, :integer
    field :persistent_keepalive, :integer
    field :allowed_ips, :string
    field :dns, :string
    field :remote_ip, EctoNetwork.INET
    field :ipv4, EctoNetwork.INET
    field :ipv6, EctoNetwork.INET

    field :latest_handshake, :utc_datetime_usec
    field :key_regenerated_at, :utc_datetime_usec, read_after_writes: true

    belongs_to :user, User

    timestamps(type: :utc_datetime_usec)
  end

  @fields ~w[
      latest_handshake
      rx_bytes
      tx_bytes
      use_site_allowed_ips
      use_site_dns
      use_site_endpoint
      use_site_mtu
      use_site_persistent_keepalive
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
    |> Common.put_default_value(:name, &FzHttp.Devices.new_name/0)
    |> Common.put_default_value(:preshared_key, &FzCommon.FzCrypto.psk/0)
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
    |> Common.trim_change(:allowed_ips)
    |> Common.trim_change(:dns)
    |> Common.trim_change(:endpoint)
    |> Common.trim_change(:name)
    |> Common.trim_change(:description)
    |> validate_length(:description, max: @description_max_length)
    |> validate_length(:name, min: 1)
    |> assoc_constraint(:user)
    |> validate_required_unless_site([:endpoint])
    |> validate_omitted_if_site(~w[
      allowed_ips
      dns
      endpoint
      persistent_keepalive
      mtu
    ]a)
    |> Common.validate_list_of_ips_or_cidrs(:allowed_ips)
    |> Common.validate_no_duplicates(:dns)
    |> Common.validate_fqdn_or_ip(:endpoint)
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
    cidr = FzHttp.Config.fetch_env!(:fz_http, :"wireguard_#{field}_network")

    case FzCommon.FzNet.rand_ip(cidr, field) do
      {:ok, ip} -> put_change(changeset, field, ip)
      {:error, :not_found} -> add_error(changeset, :base, "CIDR #{cidr} is exhausted")
    end
  end

  defp ipv4_address do
    FzHttp.Config.fetch_env!(:fz_http, :wireguard_ipv4_address)
    |> EctoNetwork.INET.cast()
  end

  defp ipv6_address do
    FzHttp.Config.fetch_env!(:fz_http, :wireguard_ipv6_address)
    |> EctoNetwork.INET.cast()
  end

  defp validate_max_devices(changeset) do
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

  defp validate_omitted_if_site(changeset, fields) when is_list(fields) do
    Common.validate_omitted(
      changeset,
      filter_site_fields(changeset, fields, use_site: true)
    )
  end

  defp validate_required_unless_site(changeset, fields) when is_list(fields) do
    validate_required(changeset, filter_site_fields(changeset, fields, use_site: false))
  end

  defp filter_site_fields(changeset, fields, use_site: use_site) when is_boolean(use_site) do
    fields
    |> Enum.map(fn field -> String.to_atom("use_site_#{field}") end)
    |> Enum.filter(fn site_field -> get_field(changeset, site_field) == use_site end)
    |> Enum.map(fn field ->
      field
      |> Atom.to_string()
      |> String.trim("use_site_")
      |> String.to_atom()
    end)
  end
end
