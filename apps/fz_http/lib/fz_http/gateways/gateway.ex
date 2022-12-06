defmodule FzHttp.Gateways.Gateway do
  @moduledoc """
  Gateway configuration schema
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias FzHttp.Sites.Site

  @foreign_key_type Ecto.UUID
  @primary_key {:id, Ecto.UUID, read_after_writes: true}

  schema "gateways" do
    field :ipv4_masquerade, :boolean, default: true
    field :ipv6_masquerade, :boolean, default: true
    field :ipv4_network, EctoNetwork.CIDR
    field :ipv6_network, EctoNetwork.CIDR
    field :wireguard_ipv4_address, EctoNetwork.INET
    field :wireguard_ipv6_address, EctoNetwork.INET
    field :wireguard_mtu, :integer, read_after_writes: true
    field :wireguard_dns, :string
    field :wireguard_public_key, :string

    belongs_to :site, Site

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def changeset(gateway, attrs) do
    gateway
    |> cast(attrs, [
      :site_id,
      :ipv4_masquerade,
      :ipv6_masquerade,
      :ipv4_network,
      :ipv6_network,
      :wireguard_ipv4_address,
      :wireguard_ipv6_address,
      :wireguard_mtu,
      :wireguard_public_key
    ])
    |> validate_required([:ipv4_masquerade, :ipv6_masquerade])
    |> assoc_constraint(:site)
  end
end
