defmodule Portal.Changes.Hooks.SantaPostureProviders do
  @moduledoc "Broadcasts Santa posture provider changes without publishing device rewrites."

  @behaviour Portal.Changes.Hooks
  alias Portal.{Changes.Change, PubSub}
  import Portal.SchemaHelpers

  @impl true
  def on_insert(lsn, data) do
    provider = struct_from_params(Portal.Santa.PostureProvider, data)
    change = %Change{lsn: lsn, op: :insert, struct: provider}
    PubSub.Changes.broadcast(provider.account_id, :posture_providers, change)
  end

  @impl true
  def on_update(lsn, old_data, data) do
    old_provider = struct_from_params(Portal.Santa.PostureProvider, old_data)
    provider = struct_from_params(Portal.Santa.PostureProvider, data)
    change = %Change{lsn: lsn, op: :update, old_struct: old_provider, struct: provider}
    PubSub.Changes.broadcast(provider.account_id, :posture_providers, change)
  end

  @impl true
  def on_delete(lsn, old_data) do
    provider = struct_from_params(Portal.Santa.PostureProvider, old_data)
    change = %Change{lsn: lsn, op: :delete, old_struct: provider}
    PubSub.Changes.broadcast(provider.account_id, :posture_providers, change)
  end
end
