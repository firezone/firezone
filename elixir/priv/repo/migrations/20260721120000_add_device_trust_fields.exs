defmodule Portal.Repo.Migrations.AddDeviceTrustFields do
  @moduledoc """
  Adds client-only fields for MDM-certificate device trust.

  The existing `device_serial` / `device_uuid` / `identifier_for_vendor`
  columns are self-reported by the client and therefore spoofable. The
  `attested_*` columns hold identifiers proven by answering the portal's
  challenge-response with an MDM-provisioned client certificate:

    * `attested_device_serial` / `attested_device_uuid` - hardware identifiers
      (serial, SMBIOS UUID / UDID) asserted in the certificate subject/SAN.
      On Android 12+ personally-owned work profiles hardware IDs are
      unavailable to MDMs, so these stay NULL there.
    * `attested_mdm_device_id` - the MDM's logical device ID asserted in the
      certificate (e.g. Intune {{DeviceId}}), the stable link to the MDM
      record on every platform.
    * `cert_serial` / `cert_fingerprint` - the pinned client
      certificate used to answer the challenge-response.
    * `verification_method` - how `verified_at` was established. Existing
      verified clients were verified by an admin, so they backfill to `manual`.
  """
  use Ecto.Migration

  def up do
    alter table(:devices) do
      add(:attested_device_serial, :string)
      add(:attested_device_uuid, :string)
      add(:attested_mdm_device_id, :string)
      add(:cert_serial, :string)
      add(:cert_fingerprint, :string)
      add(:verification_method, :string)
    end

    execute("""
    UPDATE devices SET verification_method = 'manual'
    WHERE type = 'client' AND verified_at IS NOT NULL
    """)
  end

  def down do
    alter table(:devices) do
      remove(:attested_device_serial)
      remove(:attested_device_uuid)
      remove(:attested_mdm_device_id)
      remove(:cert_serial)
      remove(:cert_fingerprint)
      remove(:verification_method)
    end
  end
end
