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

  def on_insert(_lsn, table, data, state) do
    hook = Map.get(@tables_to_hooks, table)

    if hook do
      :ok = hook.on_insert(data)
    else
      log_warning(:insert, table)
    end

    state
  end

  def on_update(_lsn, table, old_data, data, state) do
    hook = Map.get(@tables_to_hooks, table)

    if hook do
      :ok = hook.on_update(old_data, data)
    else
      log_warning(:update, table)
    end

    state
  end

  def on_delete(_lsn, table, old_data, state) do
    hook = Map.get(@tables_to_hooks, table)

    if hook do
      :ok = hook.on_delete(old_data)
    else
      log_warning(:delete, table)
    end

    state
  end

  defp log_warning(op, table) do
    Logger.warning(
      "No hook defined for #{op} on table #{table}. Please implement Domain.Events.Hooks for this table."
    )
  end
end
