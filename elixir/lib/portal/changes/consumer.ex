defmodule Portal.Changes.Consumer do
  @moduledoc """
  Dispatches decoded changes from the changes publication to their
  `Portal.Changes.Hooks` modules.

  Hooks are side effects (broadcasts, cache updates) that cannot commit
  atomically with any progress marker, so delivery is at-least-once: a crash
  before the slot advances replays the batch and duplicates the hook calls.
  Hook implementations must tolerate duplicates.
  """
  @behaviour Portal.Replication.SlotPoller

  require Logger

  alias Portal.Changes.Hooks

  @tables_to_hooks %{
    "accounts" => Hooks.Accounts,
    "actors" => Hooks.Actors,
    "groups" => Hooks.Groups,
    "memberships" => Hooks.Memberships,
    "devices" => Hooks.Devices,
    "external_identities" => Hooks.ExternalIdentities,
    "policy_authorizations" => Hooks.PolicyAuthorizations,
    "gateway_tokens" => Hooks.GatewayTokens,
    "sites" => Hooks.Sites,
    "policies" => Hooks.Policies,
    "resources" => Hooks.Resources,
    "static_device_pool_members" => Hooks.StaticDevicePoolMembers,
    "client_tokens" => Hooks.ClientTokens,
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

  @impl true
  def init_state(_config), do: %{}

  @impl true
  def on_begin(state, _msg), do: state

  @impl true
  def on_logical_message(state, _msg), do: state

  @impl true
  def on_write(state, lsn, op, table, old_data, data) do
    hook = Map.get(@tables_to_hooks, table)

    if hook do
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

  @impl true
  def flush(state), do: state

  defp log_warning(op, table) do
    Logger.warning(
      "No hook defined for #{op} on table #{table}. Please implement Portal.Changes.Hooks for this table."
    )
  end
end
