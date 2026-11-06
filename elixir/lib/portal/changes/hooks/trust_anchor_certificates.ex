defmodule Portal.Changes.Hooks.TrustAnchorCertificates do
  @behaviour Portal.Changes.Hooks
  alias Portal.{Changes.Change, PubSub, TrustAnchorCertificate}
  import Portal.SchemaHelpers

  @impl true
  def on_insert(_lsn, _data), do: :ok

  @impl true
  def on_update(_lsn, _old_data, _data), do: :ok

  @impl true
  def on_delete(lsn, old_data) do
    certificate = struct_from_params(TrustAnchorCertificate, old_data)
    change = %Change{lsn: lsn, op: :delete, old_struct: certificate}

    PubSub.Changes.broadcast(certificate.account_id, :trust_anchor_certificates, change)
  end
end
