defmodule FzHttp.Devices.Device do
  @moduledoc """
  Manages Device things
  """

  use Ecto.Schema
  import Ecto.Changeset

  import FzCommon.FzNet,
    only: [
      valid_ip?: 1,
      valid_cidr?: 1
    ]

  alias FzHttp.Users.User

  schema "devices" do
    field :name, :string
    field :public_key, :string
    field :allowed_ips, :string, read_after_writes: true
    field :dns_servers, :string, read_after_writes: true
    field :private_key, FzHttp.Encrypted.Binary
    field :server_public_key, :string
    field :remote_ip, EctoNetwork.INET
    field :address, :integer, read_after_writes: true
    field :last_seen_at, :utc_datetime_usec

    belongs_to :user, User

    timestamps(type: :utc_datetime_usec)
  end

  def create_changeset(device, attrs) do
    device
    |> cast(attrs, [
      :allowed_ips,
      :dns_servers,
      :remote_ip,
      :address,
      :server_public_key,
      :private_key,
      :user_id,
      :name,
      :public_key
    ])
    |> shared_changeset()
  end

  def update_changeset(device, attrs) do
    device
    |> cast(attrs, [
      :allowed_ips,
      :dns_servers,
      :remote_ip,
      :address,
      :server_public_key,
      :private_key,
      :user_id,
      :name,
      :public_key
    ])
    |> shared_changeset()
    |> validate_required(:address)
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
    |> validate_list_of_ips_or_cidrs(:allowed_ips)
    |> validate_list_of_ips(:dns_servers)
    |> unique_constraint(:address)
    |> validate_number(:address, greater_than_or_equal_to: 2, less_than_or_equal_to: 254)
    |> unique_constraint(:public_key)
    |> unique_constraint(:private_key)
    |> unique_constraint([:user_id, :name])
  end

  defp validate_list_of_ips(changeset, field) when is_atom(field) do
    validate_change(changeset, field, fn _current_field, value ->
      try do
        for ip <- String.split(value, ",") do
          unless valid_ip?(String.trim(ip)) do
            throw(ip)
          end
        end

        []
      catch
        ip ->
          [{field, "is invalid: #{String.trim(ip)} is not a valid IPv4 / IPv6 address"}]
      end
    end)
  end

  defp validate_list_of_ips_or_cidrs(changeset, field) when is_atom(field) do
    validate_change(changeset, field, fn _current_field, value ->
      try do
        for ip_or_cidr <- String.split(value, ",") do
          trimmed_ip_or_cidr = String.trim(ip_or_cidr)

          unless valid_ip?(trimmed_ip_or_cidr) or valid_cidr?(trimmed_ip_or_cidr) do
            throw(ip_or_cidr)
          end
        end

        []
      catch
        ip_or_cidr ->
          [
            {field,
             """
             is invalid: #{String.trim(ip_or_cidr)} is not a valid IPv4 / IPv6 address or \
             CIDR range\
             """}
          ]
      end
    end)
  end
end
