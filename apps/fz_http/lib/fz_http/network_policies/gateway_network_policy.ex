defmodule FzHttp.NetworkPolicies.GatewayNetworkPolicy do
  @moduledoc """
  Gateway network policy schema
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias FzHttp.Gateways.Gateway
  alias FzHttp.NetworkPolicies.NetworkPolicy

  @foreign_key_type Ecto.UUID
  @primary_key false
  @primary_key {:id, Ecto.UUID, read_after_writes: true}

  schema "gateway_network_policies" do
    belongs_to :gateway, Gateway
    belongs_to :network_policy, NetworkPolicy

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def changeset(gateway_network_policy, attrs) do
    gateway_network_policy
    |> cast(attrs, [:gateway_id, :network_policy_id])
    |> validate_required([:gateway_id, :network_policy_id])
  end
end
