defmodule Domain.Network.Address do
  use Ecto.Schema

  @primary_key false
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "network_addresses" do
    field :address, Domain.Types.IP, primary_key: true
    belongs_to :account, Domain.Account, primary_key: true

    field :type, Ecto.Enum, values: [:ipv4, :ipv6]

    timestamps(updated_at: false)
  end
end
