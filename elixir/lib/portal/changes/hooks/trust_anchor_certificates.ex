defmodule Portal.Changes.Hooks.TrustAnchorCertificates do
  @moduledoc """
  Broadcasts trust anchor certificate changes so connected clients re-evaluate
  policy.

  Separate from the anchor's own hook because editing an anchor's certificates
  replaces these rows without necessarily writing to the anchor row itself, so
  the anchor hook alone would miss the material actually changing underneath it.
  """
  @behaviour Portal.Changes.Hooks

  alias Portal.{Changes.Change, PubSub, TrustAnchorCertificate}
  import Portal.SchemaHelpers

  @impl true
  def on_insert(lsn, data), do: broadcast(lsn, :insert, data)

  @impl true
  def on_update(lsn, _old_data, data), do: broadcast(lsn, :update, data)

  @impl true
  def on_delete(lsn, old_data), do: broadcast(lsn, :delete, old_data)

  defp broadcast(lsn, op, data) do
    certificate = struct_from_params(TrustAnchorCertificate, data)
    change = %Change{lsn: lsn, op: op, struct: certificate}

    PubSub.Changes.broadcast(certificate.account_id, :trust_anchor_certificates, change)
  end
end
