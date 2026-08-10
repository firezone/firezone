defmodule Portal.Repo.Migrations.IndexAttestedCertFingerprint do
  @moduledoc """
  Indexes the pinned certificate fingerprint so it can act as a fallback
  identity.

  Not every MDM can assert a device id: Mosyle offers only a serial number
  variable, so certificates from it carry no MDM device id at all. Those
  connects fall back to matching the pinned certificate, which needs an index
  to avoid a sequential scan over `devices` on every connect.

  The fingerprint rather than the certificate serial, because a serial is only
  unique per issuing CA (RFC 5280 4.1.2.2: "the issuer name and serial number
  identify a unique certificate"). An account may trust several anchors, and
  internal CAs commonly start numbering at 1, so two of them issuing serial 1
  is ordinary rather than exotic. A SHA-256 of the DER needs no such scoping.
  """
  use Ecto.Migration

  @disable_ddl_transaction true

  def up do
    create_if_not_exists(
      unique_index(:devices, [:account_id, :actor_id, :last_attested_cert_fingerprint],
        where: "last_attested_cert_fingerprint IS NOT NULL",
        name: :devices_account_id_actor_id_last_attested_cert_fingerprint_index,
        concurrently: true
      )
    )
  end

  def down do
    drop_if_exists(
      index(:devices, [:account_id, :actor_id, :last_attested_cert_fingerprint],
        name: :devices_account_id_actor_id_last_attested_cert_fingerprint_index,
        concurrently: true
      )
    )
  end
end
