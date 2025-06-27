defmodule Domain.Events.ReplicationConnection do
  alias Domain.Events.Hooks

  use Domain.Replication.Connection,
    # Allow up to 60 seconds of lag before alerting
    warning_threshold_ms: 60 * 1_000,

    # Allow up to 30 minutes of lag before bypassing hooks
    error_threshold_ms: 30 * 60 * 1_000

  require Logger

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

  def on_insert(_lsn, table, data) do
    hook = Map.get(@tables_to_hooks, table)

    if hook do
      hook.on_insert(data)
    else
      log_warning(:insert, table)
      :ok
    end
  end

  def on_update(_lsn, table, old_data, data) do
    hook = Map.get(@tables_to_hooks, table)

    if hook do
      hook.on_update(old_data, data)
    else
      log_warning(:update, table)
      :ok
    end
  end

  def on_delete(_lsn, table, old_data) do
    hook = Map.get(@tables_to_hooks, table)

    if hook do
      hook.on_delete(old_data)
    else
      log_warning(:delete, table)
      :ok
    end
  end

  defp log_warning(op, table) do
    Logger.warning(
      "No hook defined for #{op} on table #{table}. Please implement Domain.Events.Hooks for this table."
    )
  end
end
