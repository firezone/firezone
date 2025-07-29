defmodule Domain.Clients.Cache do
  @moduledoc """
    This cache is used in the client channel to maintain materialized views of the client access state.
    The cache is updated via WAL messages streamed from the Domain.Events.ReplicationConnection module.

    We use basic data structures and binary representations instead of full Ecto schema structs
    to minimize memory usage. The rough structure of the two cached data structures and some napkin math
    on their memory usage (assuming "worst-case" usage scenarios) is described below.

      Data structure:

        %{
          policies: %{id:uuidv4:16 => {
            resource_id:uuidv4:16,
            actor_group_id:uuidv4:16,
            conditions:[%{
              property:atom:0,
              operator:atom:0,
              values:
              [string:varies]:(16 * len)}:(40 - small map)
              ]:(16 * len)
            }:16
          }:(num_keys * 1.8 * 8 - large map)

          resources: %{id:uuidv4:16 => {
            name: string:(~ 1.25 bytes per char),
            address:string:(~ 1.25 bytes per char),
            address_description:string:(~ 1.25 bytes per char),
            ip_stack: atom:0,
            type: atom:0,
            filters: [%{protocol: atom:0, ports: [string:(~ 1.25 bytes per char)]}:(40 - small map)]:(16 * len),
            gateway_groups: [%{
              name:string:(~1.25 bytes per char),
              resource_id:uuidv4:16,
              gateway_group_id:uuidv4:16
            }]
          }},

          memberships: %{group_id:uuidv4:16 => membership_id:uuidv4:16}
        }


      For 1,000 policies, 500 resources, 100 memberships, 100 flows (per connected client):

        513,400 bytes, 280,700 bytes, 24,640 bytes, 24,640 bytes

      = 843,380 bytes
      = ~ 1 MB (per client)

  """

  alias Domain.{Actors, Clients, Resources, Policies}

  require OpenTelemetry.Tracer

  @doc """
    Fetches relevant policies, resources, and memberships from the DB and transforms them into the cache format.
    This is used to hydrate the cache when a client connects.
  """
  def hydrate(%Actors.Actor{} = actor) do
    attributes = %{
      actor_id: actor.id,
      account_id: actor.account_id
    }

    OpenTelemetry.Tracer.with_span "Clients.Cache.hydrate", attributes: attributes do
      {_policies, cache} =
        Policies.all_policies_for_actor!(actor)
        |> Enum.map_reduce(%{policies: %{}, resources: %{}}, fn policy, cache ->
          resource = resource_to_cache(policy.resource)
          resources = Map.put(cache.resources, resource.id, resource)

          policy = policy_to_cache(policy)
          policies = Map.put(cache.policies, policy.id, policy)

          {policy, Map.merge(cache, %{policies: policies, resources: resources})}
        end)

      memberships =
        Actors.all_memberships_for_actor!(actor)
        |> Enum.map(fn membership ->
          {Ecto.UUID.dump!(membership.group_id), Ecto.UUID.dump!(membership.id)}
        end)
        |> Enum.into(%{})

      Map.put(cache, :memberships, memberships)
    end
  end

  def authorized_resources(%{} = cache, %Clients.Client{} = client) do
    resource_ids =
      cache.policies
      |> Map.values()
      |> Policies.filter_by_conforming_policies_for_client(client)
      |> Enum.map(& &1.resource_id)
      |> Enum.uniq()

    cache.resources
    |> Map.take(resource_ids)
    |> Map.values()
    |> Resources.adapt_resources_for_version(client.last_seen_version)
  end

  defp resource_to_cache(%Resources.Resource{} = resource) do
    %{
      id: Ecto.UUID.dump!(resource.id),
      name: resource.name,
      address: resource.address,
      address_description: resource.address_description,
      ip_stack: resource.ip_stack,
      filters: Enum.map(resource.filters, &Map.from_struct/1),
      gateway_groups:
        Enum.map(resource.gateway_groups, fn group ->
          %{
            id: Ecto.UUID.dump!(group.id),
            name: group.name,
            resource_id: Ecto.UUID.dump!(group.resource_id)
          }
        end)
    }
  end

  defp policy_to_cache(%Policies.Policy{} = policy) do
    %{
      id: Ecto.UUID.dump!(policy.id),
      resource_id: Ecto.UUID.dump!(policy.resource_id),
      actor_group_id: Ecto.UUID.dump!(policy.actor_group_id),
      conditions: Enum.map(policy.conditions, &Map.from_struct/1)
    }
  end
end
