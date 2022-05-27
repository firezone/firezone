defmodule FzHttp.Networks.Network do
  @moduledoc """
  Manages WireGuard networks.
  """

  use Ecto.Schema
  import Ecto.Changeset
  require Logger

  import FzHttp.SharedValidators,
    only: [
      validate_mtu: 2,
      validate_cidr_inclusion: 3,
      validate_ip_pair_existence: 2
    ]

  @interface_name_max_length 15
  @interface_name_min_length 1
  @listen_port_min 1
  @listen_port_max 65_535

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "networks" do
    field :interface_name, :string
    field :private_key, FzHttp.Encrypted.Binary
    field :public_key, :string
    field :listen_port, :integer
    field :ipv4_address, EctoNetwork.INET
    field :ipv4_network, EctoNetwork.CIDR
    field :ipv6_address, EctoNetwork.INET
    field :ipv6_network, EctoNetwork.CIDR
    field :mtu, :integer, read_after_writes: true
    field :require_privileged, :boolean, read_after_writes: true

    timestamps(type: :utc_datetime_usec)
  end

  def create_changeset(network, attrs) do
    network
    |> cast(attrs, [
      :interface_name,
      :private_key,
      :public_key,
      :listen_port,
      :ipv4_address,
      :ipv4_network,
      :ipv6_address,
      :ipv6_network,
      :mtu,
      :require_privileged
    ])
    |> unique_constraint(:interface_name)
    |> unique_constraint(:private_key)
    |> unique_constraint(:listen_port)
    |> unique_constraint(:ipv4_address)
    |> unique_constraint(:ipv6_address)
    |> validate_ip_pair_existence([{:ipv4_network, :ipv4_address}, {:ipv6_network, :ipv6_address}])
    |> exclusion_constraint(:ipv4_network, name: :networks_ipv4_network_excl)
    |> exclusion_constraint(:ipv6_network, name: :networks_ipv6_network_excl)
    |> validate_required([
      :interface_name,
      :private_key,
      :public_key,
      :listen_port
    ])
    |> validate_length(:interface_name,
      greater_than_or_equal_to: @interface_name_min_length,
      less_than_or_equal_to: @interface_name_max_length
    )
    |> validate_number(:listen_port,
      greater_than_or_equal_to: @listen_port_min,
      less_than_or_equal_to: @listen_port_max
    )
    |> validate_mtu(:mtu)
    |> validate_cidr_inclusion(:ipv4_network, :ipv4_address)
    |> validate_cidr_inclusion(:ipv6_network, :ipv6_address)
  end
end
