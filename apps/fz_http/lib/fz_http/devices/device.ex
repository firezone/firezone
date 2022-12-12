defmodule FzHttp.Devices.Device do
  @moduledoc """
  Manages Device things
  """

  use Ecto.Schema
  import Ecto.Changeset
  require Logger

  import FzHttp.Validators.Common,
    only: [
      validate_fqdn_or_ip: 2,
      validate_omitted: 2,
      validate_no_duplicates: 2,
      validate_list_of_ips_or_cidrs: 2
    ]

  alias FzHttp.{Devices, Users.User}

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
    field :ipv4, EctoNetwork.INET, read_after_writes: true
    field :ipv6, EctoNetwork.INET, read_after_writes: true
    field :latest_handshake, :utc_datetime_usec
    field :key_regenerated_at, :utc_datetime_usec, read_after_writes: true

    belongs_to :user, User

    timestamps(type: :utc_datetime_usec)
  end

  def create_changeset(attrs) do
    %__MODULE__{}
    |> shared_cast(attrs)
    |> shared_changeset()
    |> validate_max_devices()
  end

  def update_changeset(device, attrs) do
    device
    |> shared_cast(attrs)
    |> shared_changeset()
  end

  defp shared_cast(device, attrs) do
    device
    |> cast(attrs, [
      :latest_handshake,
      :rx_bytes,
      :tx_bytes,
      :use_site_allowed_ips,
      :use_site_dns,
      :use_site_endpoint,
      :use_site_mtu,
      :use_site_persistent_keepalive,
      :allowed_ips,
      :dns,
      :endpoint,
      :mtu,
      :persistent_keepalive,
      :remote_ip,
      :ipv4,
      :ipv6,
      :user_id,
      :name,
      :description,
      :public_key,
      :preshared_key,
      :key_regenerated_at
    ])
    |> update_change(:allowed_ips, &String.trim/1)
    |> update_change(:dns, &String.trim/1)
    |> update_change(:endpoint, &String.trim/1)
    |> update_change(:name, &String.trim/1)
    |> update_change(:description, &String.trim/1)
  end

  defp shared_changeset(changeset) do
    changeset
    |> assoc_constraint(:user)
    |> validate_required([
      :user_id,
      :name,
      :public_key
    ])
    |> validate_required_if_enabled(
      :ipv4,
      FzHttp.Config.fetch_env!(:fz_http, :wireguard_ipv4_enabled)
    )
    |> validate_required_if_enabled(
      :ipv6,
      FzHttp.Config.fetch_env!(:fz_http, :wireguard_ipv6_enabled)
    )
    |> validate_required_unless_site([:endpoint])
    |> validate_omitted_if_site([
      :allowed_ips,
      :dns,
      :endpoint,
      :persistent_keepalive,
      :mtu
    ])
    |> validate_list_of_ips_or_cidrs(:allowed_ips)
    |> validate_no_duplicates(:dns)
    |> validate_fqdn_or_ip(:endpoint)
    |> validate_number(:persistent_keepalive,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: 120
    )
    |> validate_number(:mtu,
      greater_than_or_equal_to: 576,
      less_than_or_equal_to: 1500
    )
    |> validate_length(:description, max: @description_max_length)
    |> unique_constraint(:ipv4)
    |> unique_constraint(:ipv6)
    |> validate_exclusion(:ipv4, [ipv4_address()])
    |> validate_exclusion(:ipv6, [ipv6_address()])
    |> unique_constraint(:public_key)
    |> unique_constraint([:user_id, :name])
  end

  defp ipv4_address do
    FzHttp.Config.fetch_env!(:fz_http, :wireguard_ipv4_address)
    |> EctoNetwork.INET.cast()
  end

  defp ipv6_address do
    FzHttp.Config.fetch_env!(:fz_http, :wireguard_ipv6_address)
    |> EctoNetwork.INET.cast()
  end

  defp validate_required_if_enabled(changeset, field, true),
    do: validate_required(changeset, field)

  defp validate_required_if_enabled(changeset, _, _), do: changeset

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
    validate_omitted(changeset, filter_site_fields(changeset, fields, use_site: true))
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
