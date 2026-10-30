defmodule Portal.Changes.Hooks.IntunePostureProviders do
  @moduledoc """
  Hooks for changes to a Microsoft Intune provider.

  A run ends by writing its provider row, so this reports a finished sync as
  well as an edit. The synced devices have hooks of their own that publish a
  row only under the identifiers a client device can match it on.
  """

  @behaviour Portal.Changes.Hooks
  alias Portal.{Changes.Change, PubSub}
  import Portal.SchemaHelpers

  @impl true
  def on_insert(lsn, data) do
    provider = struct_from_params(Portal.Intune.PostureProvider, data)
    change = %Change{lsn: lsn, op: :insert, struct: provider}

    PubSub.Changes.broadcast(provider.account_id, :posture_providers, change)
  end

  @impl true
  def on_update(lsn, old_data, data) do
    old_provider = struct_from_params(Portal.Intune.PostureProvider, old_data)
    provider = struct_from_params(Portal.Intune.PostureProvider, data)
    change = %Change{lsn: lsn, op: :update, old_struct: old_provider, struct: provider}

    PubSub.Changes.broadcast(provider.account_id, :posture_providers, change)
  end

  @impl true
  def on_delete(lsn, old_data) do
    provider = struct_from_params(Portal.Intune.PostureProvider, old_data)
    change = %Change{lsn: lsn, op: :delete, old_struct: provider}

    PubSub.Changes.broadcast(provider.account_id, :posture_providers, change)
  end
end
