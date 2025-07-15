defmodule API.Client.Cache do
  @moduledoc """
    Functions that operate on Phoenix.Socket to maintain access-related information in the client's
    channel. This is done to be able to act on WAL events broadcasted from the replication consumer
    without having to circle back to the database to re-evaluate policies each time a relevant event
    occurs.
  """
  import Phoenix.Socket, only: [assign: 3]
  alias Domain.{Gateways, Policies, Resources}

  defmodule GatewayGroup do
    @moduledoc """
      A gateway group as it is stored in the cache, which is a memory-friendly representation
      of the `Domain.Gateways.Group` schema. It includes only the fields that are necessary
      to render down to the client as a Site.
    """

    @type t :: %__MODULE__{
            id: Ecto.UUID.t(),
            name: String.t()
          }

    defstruct [:id, :name]

    def from(%Gateways.Group{} = group) do
      %__MODULE__{
        id: Ecto.UUID.dump!(group.id),
        name: group.name
      }
    end
  end

  defmodule Policy do
    @moduledoc """
      A policy as it is stored in the cache, which is a memory-friendly representation
      of the `Domain.Policies.Policy` schema. It includes only the fields that are necessary
      to make access decisions for the connected client.
    """

    @type t :: %__MODULE__{
            id: Ecto.UUID.t(),
            actor_group_id: Ecto.UUID.t(),
            resource_id: Ecto.UUID.t(),
            conditions: list()
          }

    defstruct [:id, :actor_group_id, :resource_id, :conditions]

    def from(%Policies.Policy{} = policy) do
      %__MODULE__{
        id: Ecto.UUID.dump!(policy.id),
        actor_group_id: Ecto.UUID.dump!(policy.actor_group_id),
        resource_id: Ecto.UUID.dump!(policy.resource_id),
        conditions: policy.conditions
      }
    end
  end

  defmodule Resource do
    @moduledoc """
      A resource as it is stored in the cache, which is a memory-friendly representation
      of the `Domain.Resources.Resource` schema. It includes only the fields that are necessary
      to render down to the client.
    """

    @type t :: %__MODULE__{
            id: Ecto.UUID.t(),
            type: atom(),
            address: String.t(),
            address_description: String.t() | nil,
            ip_stack: atom() | nil,
            name: String.t(),
            filters: list(),
            gateway_groups: list(GatewayGroup.t())
          }

    defstruct [
      :id,
      :type,
      :address,
      :address_description,
      :ip_stack,
      :name,
      :filters,
      :gateway_groups
    ]

    def from(%Resources.Resource{} = resource) do
      %__MODULE__{
        id: Ecto.UUID.dump!(resource.id),
        type: resource.type,
        address: resource.address,
        address_description: resource.address_description,
        ip_stack: resource.ip_stack,
        name: resource.name,
        filters: resource.filters,
        gateway_groups: Enum.map(resource.gateway_groups, &GatewayGroup.from/1)
      }
    end
  end

  @type t :: %__MODULE__{
          policies: %{Ecto.UUID.t() => Policy.t()},
          resources: %{Ecto.UUID.t() => Resource.t()},
          actor_group_ids: MapSet.t(Ecto.UUID.t())
        }

  defstruct [:policies, :resources, :actor_group_ids]

  @doc """
    Hydrates the cache with a fresh list of policies relevant to the connected client and
    a list of actor group IDs that the client's actor belongs to.
  """
  @spec hydrate(list(any()), list(any())) :: __MODULE__.t()
  def hydrate(policies, actor_group_ids) do
    actor_group_ids =
      actor_group_ids
      |> Enum.map(&Ecto.UUID.dump!/1)
      |> MapSet.new()

    # convert a list of policies with nested resources and gateway groups to the cache structure
    {_policies, cache} =
      policies
      |> Enum.map_reduce(%__MODULE__{actor_group_ids: actor_group_ids}, fn policy, acc ->
        resource = policy.resource

        {policy,
         acc
         |> Map.put(:policies, Map.put(acc.policies, policy.id, Policy.from(policy)))
         |> Map.put(:resources, Map.put(acc.resources, resource.id, Resource.from(resource)))}
      end)

    cache
  end
end
