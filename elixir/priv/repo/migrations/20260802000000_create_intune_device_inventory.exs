defmodule Portal.Repo.Migrations.CreateIntuneDeviceInventory do
  use Ecto.Migration

  def up do
    create table(:device_integrations, primary_key: false) do
      add(:account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        null: false,
        primary_key: true
      )

      add(:id, :binary_id, null: false, primary_key: true)
      add(:type, :string, null: false)
    end

    create(
      constraint(:device_integrations, :type_must_be_valid,
        check: "type IN ('intune')"
      )
    )

    create(
      unique_index(:device_integrations, [:account_id, :type],
        name: :device_integrations_account_id_type_index
      )
    )

    create table(:intune_integrations, primary_key: false) do
      add(:id, :binary_id, null: false, primary_key: true)

      add(:account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:name, :string, null: false)
      add(:tenant_id, :string, null: false)
      add(:is_verified, :boolean, default: false, null: false)
      add(:is_disabled, :boolean, default: false, null: false)
      add(:disabled_reason, :string)
      add(:synced_at, :timestamptz)
      add(:errored_at, :timestamptz)
      add(:error_message, :text)
      timestamps(type: :timestamptz)
    end

    create(index(:intune_integrations, [:account_id]))

    execute(
      """
      ALTER TABLE intune_integrations
      ADD CONSTRAINT intune_integrations_device_integration_id_fkey
      FOREIGN KEY (account_id, id)
      REFERENCES device_integrations(account_id, id)
      ON DELETE CASCADE
      """,
      """
      ALTER TABLE intune_integrations
      DROP CONSTRAINT intune_integrations_device_integration_id_fkey
      """
    )

    create table(:intune_devices, primary_key: false) do
      add(:id, :binary_id, primary_key: true, null: false)

      add(:account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:device_integration_id, :binary_id, null: false)
      add(:device_id, :binary_id)

      add(:intune_id, :string, null: false)
      add(:device_name, :string)
      add(:managed_device_name, :string)
      add(:serial_number, :citext)
      add(:entra_device_id, :string)

      add(:user_id, :string)
      add(:user_principal_name, :string)
      add(:user_display_name, :string)
      add(:email_address, :string)

      add(:operating_system, :string)
      add(:os_version, :string)
      add(:model, :string)
      add(:manufacturer, :string)

      add(:compliance_state, :string)
      add(:management_agent, :string)
      add(:managed_device_owner_type, :string)
      add(:device_enrollment_type, :string)
      add(:device_registration_state, :string)
      add(:partner_reported_threat_state, :string)
      add(:jail_broken, :string)
      add(:is_encrypted, :boolean)
      add(:is_supervised, :boolean)

      add(:enrolled_at, :timestamptz)
      add(:last_sync_at, :timestamptz)
      add(:compliance_grace_period_expiration_at, :timestamptz)
      add(:synced_at, :timestamptz, null: false)

      # Preserve the provider payload so adding provider-specific fields does not
      # require a schema migration before the next sync can retain them.
      add(:attributes, :map, null: false, default: %{})

      timestamps(type: :timestamptz)
    end

    execute(
      """
      ALTER TABLE intune_devices
      ADD CONSTRAINT intune_devices_device_integration_id_fkey
      FOREIGN KEY (account_id, device_integration_id)
      REFERENCES device_integrations(account_id, id)
      ON DELETE CASCADE
      """,
      """
      ALTER TABLE intune_devices
      DROP CONSTRAINT intune_devices_device_integration_id_fkey
      """
    )

    execute(
      """
      ALTER TABLE intune_devices
      ADD CONSTRAINT intune_devices_device_id_fkey
      FOREIGN KEY (account_id, device_id)
      REFERENCES devices(account_id, id)
      ON DELETE SET NULL (device_id)
      """,
      """
      ALTER TABLE intune_devices
      DROP CONSTRAINT intune_devices_device_id_fkey
      """
    )

    create(index(:intune_devices, [:account_id, :device_integration_id, :intune_id]))

    create(index(:intune_devices, [:account_id, :device_id]))
    create(index(:intune_devices, [:account_id, :serial_number]))
    create(index(:intune_devices, [:account_id, :synced_at]))

    execute(create_device_inventory_view(), "DROP VIEW IF EXISTS device_inventory")
  end

  def down do
    execute("DROP VIEW IF EXISTS device_inventory")
    drop(table(:intune_devices))
    drop(table(:intune_integrations))
    drop(table(:device_integrations))
  end

  defp create_device_inventory_view do
    """
    CREATE VIEW device_inventory AS
    SELECT
      COALESCE(d.id, i.id) AS id,
      i.account_id,
      d.id AS device_id,
      i.id AS intune_device_id,
      i.device_integration_id,
      d.actor_id,
      COALESCE(i.device_name, i.managed_device_name, d.name) AS name,
      (d.id IS NOT NULL) AS connected,
      d.firezone_id,
      d.ipv4,
      d.ipv6,
      d.device_serial,
      d.device_uuid,
      d.identifier_for_vendor,
      d.firebase_installation_id,
      d.hostname,
      d.last_attested_device_serial,
      d.last_attested_device_uuid,
      d.last_attested_mdm_device_id,
      d.last_attested_cert_serial,
      d.last_attested_cert_fingerprint,
      d.last_attested_at,
      d.verified_at,
      d.last_seen_user_agent,
      d.last_seen_remote_ip,
      d.last_seen_remote_ip_location_region,
      d.last_seen_remote_ip_location_city,
      d.last_seen_remote_ip_location_lat,
      d.last_seen_remote_ip_location_lon,
      d.last_seen_version,
      d.last_seen_at,
      i.intune_id,
      i.device_name AS intune_device_name,
      i.managed_device_name AS intune_managed_device_name,
      i.serial_number AS intune_serial_number,
      i.entra_device_id AS intune_entra_device_id,
      i.user_id AS intune_user_id,
      i.user_principal_name AS intune_user_principal_name,
      i.user_display_name AS intune_user_display_name,
      i.email_address AS intune_email_address,
      i.operating_system AS intune_operating_system,
      i.os_version AS intune_os_version,
      i.model AS intune_model,
      i.manufacturer AS intune_manufacturer,
      i.compliance_state AS intune_compliance_state,
      i.management_agent AS intune_management_agent,
      i.managed_device_owner_type AS intune_managed_device_owner_type,
      i.device_enrollment_type AS intune_device_enrollment_type,
      i.device_registration_state AS intune_device_registration_state,
      i.partner_reported_threat_state AS intune_partner_reported_threat_state,
      i.jail_broken AS intune_jail_broken,
      i.is_encrypted AS intune_is_encrypted,
      i.is_supervised AS intune_is_supervised,
      i.enrolled_at AS intune_enrolled_at,
      i.last_sync_at AS intune_last_sync_at,
      i.compliance_grace_period_expiration_at AS intune_compliance_grace_period_expiration_at,
      i.attributes AS intune_attributes,
      COALESCE(d.inserted_at, i.inserted_at) AS inserted_at,
      GREATEST(d.updated_at, i.updated_at) AS updated_at
    FROM intune_devices AS i
    LEFT JOIN devices AS d
      ON d.account_id = i.account_id
      AND d.id = i.device_id
      AND d.type = 'client'

    UNION ALL

    SELECT
      d.id AS id,
      d.account_id,
      d.id AS device_id,
      NULL::uuid AS intune_device_id,
      NULL::uuid AS device_integration_id,
      d.actor_id,
      d.name,
      TRUE AS connected,
      d.firezone_id,
      d.ipv4,
      d.ipv6,
      d.device_serial,
      d.device_uuid,
      d.identifier_for_vendor,
      d.firebase_installation_id,
      d.hostname,
      d.last_attested_device_serial,
      d.last_attested_device_uuid,
      d.last_attested_mdm_device_id,
      d.last_attested_cert_serial,
      d.last_attested_cert_fingerprint,
      d.last_attested_at,
      d.verified_at,
      d.last_seen_user_agent,
      d.last_seen_remote_ip,
      d.last_seen_remote_ip_location_region,
      d.last_seen_remote_ip_location_city,
      d.last_seen_remote_ip_location_lat,
      d.last_seen_remote_ip_location_lon,
      d.last_seen_version,
      d.last_seen_at,
      NULL::text AS intune_id,
      NULL::text AS intune_device_name,
      NULL::text AS intune_managed_device_name,
      NULL::citext AS intune_serial_number,
      NULL::text AS intune_entra_device_id,
      NULL::text AS intune_user_id,
      NULL::text AS intune_user_principal_name,
      NULL::text AS intune_user_display_name,
      NULL::text AS intune_email_address,
      NULL::text AS intune_operating_system,
      NULL::text AS intune_os_version,
      NULL::text AS intune_model,
      NULL::text AS intune_manufacturer,
      NULL::text AS intune_compliance_state,
      NULL::text AS intune_management_agent,
      NULL::text AS intune_managed_device_owner_type,
      NULL::text AS intune_device_enrollment_type,
      NULL::text AS intune_device_registration_state,
      NULL::text AS intune_partner_reported_threat_state,
      NULL::text AS intune_jail_broken,
      NULL::boolean AS intune_is_encrypted,
      NULL::boolean AS intune_is_supervised,
      NULL::timestamp(6) with time zone AS intune_enrolled_at,
      NULL::timestamp(6) with time zone AS intune_last_sync_at,
      NULL::timestamp(6) with time zone AS intune_compliance_grace_period_expiration_at,
      NULL::jsonb AS intune_attributes,
      d.inserted_at,
      d.updated_at
    FROM devices AS d
    WHERE d.type = 'client'
      AND NOT EXISTS (
        SELECT 1
        FROM intune_devices AS i
        WHERE i.account_id = d.account_id
          AND i.device_id = d.id
      )
    """
  end
end
