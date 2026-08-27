defmodule Portal.Changes.Hooks.DefenderPostureProviders do
  @moduledoc """
  Hooks for changes to a Microsoft Defender for Endpoint provider.

  A run ends by writing its provider row, so this reports a finished sync as
  well as an edit. The synced devices are deliberately not in the publication:
  a run rewrites every device it reports, so subscribing them would carry one
  event per device every couple of hours.
  """

  @behaviour Portal.Changes.Hooks
  alias Portal.{Changes.Change, PubSub}
  import Portal.SchemaHelpers

  @impl true
  def on_insert(lsn, data) do
    provider = struct_from_params(Portal.Defender.PostureProvider, data)
    change = %Change{lsn: lsn, op: :insert, struct: provider}

    PubSub.Changes.broadcast(provider.account_id, :posture_providers, change)
  end

  @impl true
  def on_update(lsn, old_data, data) do
    old_provider = struct_from_params(Portal.Defender.PostureProvider, old_data)
    provider = struct_from_params(Portal.Defender.PostureProvider, data)
    change = %Change{lsn: lsn, op: :update, old_struct: old_provider, struct: provider}

    PubSub.Changes.broadcast(provider.account_id, :posture_providers, change)
  end

  @impl true
  def on_delete(lsn, old_data) do
    provider = struct_from_params(Portal.Defender.PostureProvider, old_data)
    change = %Change{lsn: lsn, op: :delete, old_struct: provider}

    PubSub.Changes.broadcast(provider.account_id, :posture_providers, change)
  end
end
