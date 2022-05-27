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
      validate_ip: 2,
      validate_cidr: 2
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
      :mtu
    ])
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
    |> validate_ip(:ipv4_address)
    |> validate_ip(:ipv6_address)
    |> validate_cidr(:ipv4_network)
    |> validate_cidr(:ipv6_network)
  end
end
