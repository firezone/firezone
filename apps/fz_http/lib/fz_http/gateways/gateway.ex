defmodule FzHttp.Gateways.Gateway do
  @moduledoc """
  The `Gateway` schema.
  """

  use FzHttp, :schema
  import Ecto.Changeset

  schema "gateways" do
    field :name, :string
    field :ipv4_masquerade, :boolean, read_after_writes: true
    field :ipv6_masquerade, :boolean, read_after_writes: true
    field :ipv4_address, EctoNetwork.INET
    field :ipv6_address, EctoNetwork.INET
    field :mtu, :integer, read_after_writes: true
    field :public_key, :string

    timestamps()
  end

  def changeset(gateway, attrs) do
    gateway
    |> cast(attrs, [
      :name,
      :ipv4_masquerade,
      :ipv6_masquerade,
      :ipv4_address,
      :ipv6_address,
      :mtu,
      :public_key
    ])
    |> validate_required(:name)
    |> unique_constraint(:name)
    |> unique_constraint(:ipv4_address)
    |> unique_constraint(:ipv6_address)
  end
end
