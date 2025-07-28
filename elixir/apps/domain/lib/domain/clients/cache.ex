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

          actor_group_memberships:mapset<uuidv4>:(16 * 1.8 * 8 * len),
          flow_ids:mapset<uuidv4>:(16 * 1.8 * 8 * len),
        }


      For 1,000 policies, 500 resources, 100 memberships, 100 flows (per connected client):

        513,400 bytes, 280,700 bytes, 24,640 bytes, 24,640 bytes

      = 843,380 bytes
      = ~ 1 MB (per client)

  """

  alias Domain.{Clients, Resources, Policies}

  require OpenTelemetry.Tracer
end
