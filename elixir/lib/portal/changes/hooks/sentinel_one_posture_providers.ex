defmodule Portal.Changes.Hooks.SentinelOnePostureProviders do
  @moduledoc """
  Hooks for changes to a SentinelOne posture provider.

  Device rows are deliberately absent from the publication because every sync
  rewrites every endpoint it sees. The provider row is enough to refresh the UI
  when a run completes or its state changes.
  """

  @behaviour Portal.Changes.Hooks
  alias Portal.{Changes.Change, PubSub}
  import Portal.SchemaHelpers

  @impl true
  def on_insert(lsn, data) do
    provider = struct_from_params(Portal.SentinelOne.PostureProvider, data)
    change = %Change{lsn: lsn, op: :insert, struct: provider}

    PubSub.Changes.broadcast(provider.account_id, :posture_providers, change)
  end

  @impl true
  def on_update(lsn, old_data, data) do
    old_provider = struct_from_params(Portal.SentinelOne.PostureProvider, old_data)
    provider = struct_from_params(Portal.SentinelOne.PostureProvider, data)
    change = %Change{lsn: lsn, op: :update, old_struct: old_provider, struct: provider}

    PubSub.Changes.broadcast(provider.account_id, :posture_providers, change)
  end

  @impl true
  def on_delete(lsn, old_data) do
    provider = struct_from_params(Portal.SentinelOne.PostureProvider, old_data)
    change = %Change{lsn: lsn, op: :delete, old_struct: provider}

    PubSub.Changes.broadcast(provider.account_id, :posture_providers, change)
  end
end
