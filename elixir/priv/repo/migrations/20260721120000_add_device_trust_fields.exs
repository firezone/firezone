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
    * `cert_serial` / `cert_fingerprint` - the pinned client certificate used
      to answer the challenge-response.

  An attested identifier anchors a physical device, so each one is unique per
  actor: the partial unique indexes let the attested-first lookup merge a
  reinstalled client (new `firezone_id`, same attested identity) back onto its
  existing device row instead of creating a duplicate.

  Zero-downtime notes: the column adds are nullable with no default, so they
  are metadata-only. The unique indexes are built CONCURRENTLY (hence
  `@disable_ddl_transaction`; the migration lock stays on since the repo uses
  `migration_lock: :pg_advisory_lock`, which CONCURRENTLY does not deadlock
  against) so writes to `devices` (client connects) are never blocked; the
  indexes are partial over columns that are all NULL at creation time, so the
  builds are cheap. If a concurrent build is interrupted it can leave an
  INVALID index, which is cleaned up by re-running the migration after
  `DROP INDEX`.
  """
  use Ecto.Migration

  @disable_ddl_transaction true

  def up do
    alter table(:devices) do
      add(:attested_device_serial, :string)
      add(:attested_device_uuid, :string)
      add(:attested_mdm_device_id, :string)
      add(:cert_serial, :string)
      add(:cert_fingerprint, :string)
    end

    create(
      unique_index(:devices, [:account_id, :actor_id, :attested_device_serial],
        where: "attested_device_serial IS NOT NULL",
        name: :devices_account_id_actor_id_attested_device_serial_index,
        concurrently: true
      )
    )

    create(
      unique_index(:devices, [:account_id, :actor_id, :attested_device_uuid],
        where: "attested_device_uuid IS NOT NULL",
        name: :devices_account_id_actor_id_attested_device_uuid_index,
        concurrently: true
      )
    )

    create(
      unique_index(:devices, [:account_id, :actor_id, :attested_mdm_device_id],
        where: "attested_mdm_device_id IS NOT NULL",
        name: :devices_account_id_actor_id_attested_mdm_device_id_index,
        concurrently: true
      )
    )
  end

  def down do
    drop(
      index(:devices, [:account_id, :actor_id, :attested_mdm_device_id],
        name: :devices_account_id_actor_id_attested_mdm_device_id_index
      )
    )

    drop(
      index(:devices, [:account_id, :actor_id, :attested_device_uuid],
        name: :devices_account_id_actor_id_attested_device_uuid_index
      )
    )

    drop(
      index(:devices, [:account_id, :actor_id, :attested_device_serial],
        name: :devices_account_id_actor_id_attested_device_serial_index
      )
    )

    alter table(:devices) do
      remove(:attested_device_serial)
      remove(:attested_device_uuid)
      remove(:attested_mdm_device_id)
      remove(:cert_serial)
      remove(:cert_fingerprint)
    end
  end
end
