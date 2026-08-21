defmodule Portal.Changes.Hooks.TrustAnchors do
  @moduledoc """
  Broadcasts trust anchor changes so connected clients re-evaluate policy.

  A policy condition can name the anchors a device's certificate has to chain
  to, so adding, removing or re-uploading one changes which resources a
  connected device may reach. Without this the change would only take effect the
  next time each device reconnected.

  Certificates are broadcast as a change to the anchor that holds them, since
  the condition names anchors and a certificate is only ever reachable through
  one. Editing an anchor replaces its certificate rows, so the certificate hooks
  are what fire when the material behind an unchanged anchor is swapped.
  """
  @behaviour Portal.Changes.Hooks

  alias Portal.{Changes.Change, PubSub, TrustAnchor}
  import Portal.SchemaHelpers

  @impl true
  def on_insert(lsn, data), do: broadcast(lsn, :insert, data)

  @impl true
  def on_update(lsn, _old_data, data), do: broadcast(lsn, :update, data)

  @impl true
  def on_delete(lsn, old_data), do: broadcast(lsn, :delete, old_data)

  defp broadcast(lsn, op, data) do
    trust_anchor = struct_from_params(TrustAnchor, data)
    change = %Change{lsn: lsn, op: op, struct: trust_anchor}

    PubSub.Changes.broadcast(trust_anchor.account_id, :trust_anchors, change)
  end
end
