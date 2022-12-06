defmodule FzHttp.NetworkPolicies.NetworkPolicy do
  @moduledoc """
  Network policy schema
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias FzHttp.Users.User

  @foreign_key_type Ecto.UUID
  @primary_key {:id, Ecto.UUID, read_after_writes: true}

  schema "network_policies" do
    field :default_action, Ecto.Enum, values: [:accept, :deny], default: :deny
    field :destination, EctoNetwork.INET
    field :port_range_start, :integer
    field :port_range_end, :integer
    field :protocol, Ecto.Enum, values: [:tcp, :udp]

    belongs_to :user, User

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def changeset(network_policy, attrs) do
    network_policy
    |> cast(attrs, [
      :default_action,
      :destination,
      :port_range_start,
      :port_range_end,
      :protocol
    ])
    |> validate_required([:default_action, :destination])
    |> assoc_constraint(:user)
  end
end
