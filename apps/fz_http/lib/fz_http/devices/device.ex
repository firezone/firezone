defmodule FzHttp.Devices.Device do
  @moduledoc """
  Manages Device things
  """

  use Ecto.Schema
  import Ecto.Changeset
  require Logger

  import FzHttp.SharedValidators,
    only: [
      validate_fqdn_or_ip: 2,
      validate_omitted: 2,
      validate_list_of_ips: 2,
      validate_no_duplicates: 2,
      validate_list_of_ips_or_cidrs: 2
    ]

  import FzHttp.Queries.INET

  alias FzHttp.Users.User

  schema "devices" do
    field :uuid, Ecto.UUID, autogenerate: true
    field :name, :string
    field :public_key, :string
    field :use_default_allowed_ips, :boolean, read_after_writes: true, default: true
    field :use_default_dns_servers, :boolean, read_after_writes: true, default: true
    field :use_default_endpoint, :boolean, read_after_writes: true, default: true
    field :use_default_mtu, :boolean, read_after_writes: true, default: true
    field :use_default_persistent_keepalives, :boolean, read_after_writes: true, default: true
    field :endpoint, :string
    field :mtu, :integer
    field :persistent_keepalives, :integer
    field :allowed_ips, :string
    field :dns_servers, :string
    field :private_key, FzHttp.Encrypted.Binary
    field :server_public_key, :string
    field :remote_ip, EctoNetwork.INET
    field :ipv4, EctoNetwork.INET, read_after_writes: true
    field :ipv6, EctoNetwork.INET, read_after_writes: true
    field :last_seen_at, :utc_datetime_usec
    field :config_token, :string
    field :config_token_expires_at, :utc_datetime_usec

    belongs_to :user, User

    timestamps(type: :utc_datetime_usec)
  end

  def create_changeset(device, attrs) do
    device
    |> shared_cast(attrs)
    |> put_next_ip(:ipv4)
    |> put_next_ip(:ipv6)
    |> shared_changeset()
  end

  def update_changeset(device, attrs) do
    device
    |> shared_cast(attrs)
    |> shared_changeset()
  end

  def field(changeset, field) do
    get_field(changeset, field)
  end

  defp shared_cast(device, attrs) do
    device
    |> cast(attrs, [
      :use_default_allowed_ips,
      :use_default_dns_servers,
      :use_default_endpoint,
      :use_default_mtu,
      :use_default_persistent_keepalives,
      :allowed_ips,
      :dns_servers,
      :endpoint,
      :mtu,
      :persistent_keepalives,
      :remote_ip,
      :ipv4,
      :ipv6,
      :server_public_key,
      :private_key,
      :user_id,
      :name,
      :public_key,
      :config_token,
      :config_token_expires_at
    ])
  end

  defp shared_changeset(changeset) do
    changeset
    |> validate_required([
      :user_id,
      :name,
      :public_key,
      :server_public_key,
      :private_key
    ])
    |> validate_required_unless_default([
      :allowed_ips,
      :dns_servers,
      :endpoint,
      :mtu,
      :persistent_keepalives
    ])
    |> validate_omitted_if_default([
      :allowed_ips,
      :dns_servers,
      :endpoint,
      :persistent_keepalives,
      :mtu
    ])
    |> validate_list_of_ips_or_cidrs(:allowed_ips)
    |> validate_list_of_ips(:dns_servers)
    |> validate_no_duplicates(:dns_servers)
    |> validate_fqdn_or_ip(:endpoint)
    |> validate_number(:persistent_keepalives,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: 120
    )
    |> validate_number(:mtu,
      greater_than_or_equal_to: 576,
      less_than_or_equal_to: 1500
    )
    |> validate_ipv4_required()
    |> validate_ipv6_required()
    |> unique_constraint(:ipv4)
    |> unique_constraint(:ipv6)
    |> validate_exclusion(:ipv4, [ipv4_address()])
    |> validate_exclusion(:ipv6, [ipv6_address()])
    |> validate_in_network(:ipv4)
    |> validate_in_network(:ipv6)
    |> unique_constraint(:public_key)
    |> unique_constraint(:private_key)
    |> unique_constraint([:user_id, :name])
  end

  defp validate_omitted_if_default(changeset, fields) when is_list(fields) do
    fields_to_validate =
      defaulted_fields(changeset, fields)
      |> Enum.map(fn field ->
        String.trim(Atom.to_string(field), "use_default_") |> String.to_atom()
      end)

    validate_omitted(changeset, fields_to_validate)
  end

  defp validate_required_unless_default(changeset, fields) when is_list(fields) do
    fields_as_atoms = Enum.map(fields, fn field -> String.to_atom("use_default_#{field}") end)
    fields_to_validate = fields_as_atoms -- defaulted_fields(changeset, fields)
    validate_required(changeset, fields_to_validate)
  end

  defp defaulted_fields(changeset, fields) do
    fields
    |> Enum.map(fn field -> String.to_atom("use_default_#{field}") end)
    |> Enum.filter(fn field -> get_field(changeset, field) end)
  end

  defp validate_ipv4_required(changeset) do
    if Application.fetch_env!(:fz_http, :wireguard_ipv4_enabled) do
      validate_required(changeset, :ipv4)
    else
      changeset
    end
  end

  defp validate_ipv6_required(changeset) do
    if Application.fetch_env!(:fz_http, :wireguard_ipv6_enabled) do
      validate_required(changeset, :ipv6)
    else
      changeset
    end
  end

  defp validate_in_network(%Ecto.Changeset{changes: %{ipv4: ip}} = changeset, :ipv4) do
    net = Application.fetch_env!(:fz_http, :wireguard_ipv4_network)
    maybe_add_net_error(changeset, net, ip, :ipv4)
  end

  defp validate_in_network(changeset, :ipv4), do: changeset

  defp validate_in_network(%Ecto.Changeset{changes: %{ipv6: ip}} = changeset, :ipv6) do
    net = Application.fetch_env!(:fz_http, :wireguard_ipv6_network)
    maybe_add_net_error(changeset, net, ip, :ipv6)
  end

  defp validate_in_network(changeset, :ipv6), do: changeset

  def maybe_add_net_error(changeset, net, ip, ip_type) do
    %{address: address} = ip
    cidr = CIDR.parse(net)

    if CIDR.match!(cidr, address) do
      changeset
    else
      add_error(changeset, ip_type, "IP must be contained within network #{net}")
    end
  end

  defp put_next_ip(changeset, ip_type) when ip_type in [:ipv4, :ipv6] do
    case changeset do
      %Ecto.Changeset{changes: %{^ip_type => _ip}} ->
        changeset

      _ ->
        if ip = next_available(ip_type) do
          put_change(changeset, ip_type, ip)
        else
          add_error(
            changeset,
            ip_type,
            "address pool is exhausted. Increase network size or remove some devices."
          )
        end
    end
  end

  defp ipv4_address do
    {:ok, inet} =
      Application.fetch_env!(:fz_http, :wireguard_ipv4_address)
      |> EctoNetwork.INET.cast()

    inet
  end

  defp ipv6_address do
    {:ok, inet} =
      Application.fetch_env!(:fz_http, :wireguard_ipv6_address)
      |> EctoNetwork.INET.cast()

    inet
  end
end
