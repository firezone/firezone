defmodule FzHttp.Devices.Device do
  @moduledoc """
  Manages Device things
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias FzHttp.Users.User

  schema "devices" do
    field :name, :string
    field :public_key, :string
    field :allowed_ips, :string
    field :private_key, FzHttp.Encrypted.Binary
    field :server_public_key, :string
    field :remote_ip, EctoNetwork.INET
    field :octet_sequence, :integer, read_after_writes: true
    field :interface_address4, EctoNetwork.INET
    field :interface_address6, EctoNetwork.INET
    field :last_seen_at, :utc_datetime_usec

    belongs_to :user, User

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(device, attrs) do
    device
    |> cast(attrs, [
      :allowed_ips,
      :remote_ip,
      :octet_sequence,
      :interface_address4,
      :interface_address6,
      :server_public_key,
      :private_key,
      :user_id,
      :name,
      :public_key
    ])
    |> validate_required([
      :user_id,
      :name,
      :public_key,
      :server_public_key,
      :private_key
    ])
    |> unique_constraint(:public_key)
    |> unique_constraint(:private_key)
    |> unique_constraint([:user_id, :name])
  end
end
