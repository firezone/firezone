defmodule Domain.Events.ReplicationConnection do
  use Domain.Replication.Connection
  alias Domain.Events.Hooks

  @tables_to_hooks %{
    "accounts" => Hooks.Accounts,
    "actor_group_memberships" => Hooks.ActorGroupMemberships,
    "actor_groups" => Hooks.ActorGroups,
    "actors" => Hooks.Actors,
    "auth_identities" => Hooks.AuthIdentities,
    "auth_providers" => Hooks.AuthProviders,
    "clients" => Hooks.Clients,
    "gateway_groups" => Hooks.GatewayGroups,
    "gateways" => Hooks.Gateways,
    "policies" => Hooks.Policies,
    "resource_connections" => Hooks.ResourceConnections,
    "resources" => Hooks.Resources,
    "tokens" => Hooks.Tokens
  }

  def on_write(state, _lsn, op, table, old_data, data) do
    if hook = Map.get(@tables_to_hooks, table) do
      case op do
        :insert -> hook.on_insert(data)
        :update -> hook.on_update(old_data, data)
        :delete -> hook.on_delete(old_data)
      end
    else
      log_warning(op, table)
    end

    state
  end

  defp log_warning(op, table) do
    Logger.warning(
      "No hook defined for #{op} on table #{table}. Please implement Domain.Events.Hooks for this table."
    )
  end
end
