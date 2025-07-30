defmodule Domain.Changes.ReplicationConnection do
  use Domain.Replication.Connection
  alias Domain.Changes.Hooks

  @tables_to_hooks %{
    "accounts" => Hooks.Accounts,
    "actor_group_memberships" => Hooks.ActorGroupMemberships,
    "clients" => Hooks.Clients,
    "flows" => Hooks.Flows,
    "gateways" => Hooks.Gateways,
    "gateway_groups" => Hooks.GatewayGroups,
    "policies" => Hooks.Policies,
    "resource_connections" => Hooks.ResourceConnections,
    "resources" => Hooks.Resources,
    "tokens" => Hooks.Tokens
  }

  def on_write(state, lsn, op, table, old_data, data) do
    if hook = Map.get(@tables_to_hooks, table) do
      case op do
        :insert -> :ok = hook.on_insert(lsn, data)
        :update -> :ok = hook.on_update(lsn, old_data, data)
        :delete -> :ok = hook.on_delete(lsn, old_data)
      end
    else
      log_warning(op, table)
    end

    state
  end

  defp log_warning(op, table) do
    Logger.warning(
      "No hook defined for #{op} on table #{table}. Please implement Domain.Changes.Hooks for this table."
    )
  end
end
