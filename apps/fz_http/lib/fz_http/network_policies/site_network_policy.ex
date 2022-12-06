defmodule FzHttp.NetworkPolicies.SiteNetworkPolicy do
  @moduledoc """
  Gateway network policy schema
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias FzHttp.NetworkPolicies.NetworkPolicy
  alias FzHttp.Sites.Site

  @foreign_key_type Ecto.UUID
  @primary_key {:id, Ecto.UUID, read_after_writes: true}

  schema "site_network_policies" do
    belongs_to :network_policy, NetworkPolicy
    belongs_to :site, Site

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def changeset(site_network_policy, attrs) do
    site_network_policy
    |> cast(attrs, [:network_policy_id, :site_id])
    |> validate_required([:network_policy_id, :site_id])
  end
end
