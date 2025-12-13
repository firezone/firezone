defmodule Domain.Changes.ReplicationConnection do
  use Domain.Replication.Connection
  alias Domain.Changes.Hooks

  @tables_to_hooks %{
    "accounts" => Hooks.Accounts,
    "memberships" => Hooks.Memberships,
    "clients" => Hooks.Clients,
    "policy_authorizations" => Hooks.PolicyAuthorizations,
    "gateways" => Hooks.Gateways,
    "gateway_tokens" => Hooks.GatewayTokens,
    "sites" => Hooks.Sites,
    "policies" => Hooks.Policies,
    "resources" => Hooks.Resources,
    "tokens" => Hooks.Tokens,
    "portal_sessions" => Hooks.PortalSessions,
    "google_auth_providers" => Hooks.AuthProviders,
    "okta_auth_providers" => Hooks.AuthProviders,
    "entra_auth_providers" => Hooks.AuthProviders,
    "oidc_auth_providers" => Hooks.AuthProviders,
    "email_otp_auth_providers" => Hooks.AuthProviders,
    "userpass_auth_providers" => Hooks.AuthProviders,
    "entra_directories" => Hooks.Directories,
    "okta_directories" => Hooks.Directories,
    "google_directories" => Hooks.Directories,
    "relay_tokens" => Hooks.RelayTokens
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
