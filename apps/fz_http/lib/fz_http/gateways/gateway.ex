defmodule FzHttp.Gateways.Gateway do
  @moduledoc """
  The `Gateway` schema.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Ecto.UUID, read_after_writes: true}

  schema "gateways" do
    field :name, :string, read_after_writes: true
    field :ipv4_masquerade, :boolean, read_after_writes: true
    field :ipv6_masquerade, :boolean, read_after_writes: true
    field :ipv4_address, EctoNetwork.INET, read_after_writes: true
    field :ipv6_address, EctoNetwork.INET, read_after_writes: true
    field :mtu, :integer, read_after_writes: true
    field :public_key, :string
    field :registration_token, :string
    field :registration_token_created_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
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
      :public_key,
      :registration_token,
      :registration_token_created_at
    ])
    |> validate_required([:name, :registration_token, :registration_token_created_at])
    |> unique_constraint(:name)
  end
end
