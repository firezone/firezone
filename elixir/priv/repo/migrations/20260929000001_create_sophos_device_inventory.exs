defmodule Portal.Repo.Migrations.CreateSophosDeviceInventory do
  use Ecto.Migration

  def up do
    drop(constraint(:posture_providers, :type_must_be_valid))

    create(
      constraint(:posture_providers, :type_must_be_valid,
        check: "type IN ('intune', 'iru', 'defender', 'santa', 'sentinelone', 'sophos')"
      )
    )

    create table(:sophos_posture_providers, primary_key: false) do
      add(:account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        null: false,
        primary_key: true
      )

      add(
        :id,
        references(:posture_providers,
          column: :id,
          with: [account_id: :account_id],
          type: :binary_id,
          on_delete: :delete_all
        ),
        null: false,
        primary_key: true
      )

      add(:client_id, :string, null: false)
      add(:client_secret, :text, null: false)

      # Answered by whoami when the credentials are verified, never typed in.
      add(:tenant_id, :string, null: false)
      add(:data_region_url, :string, null: false)

      add(:is_verified, :boolean, default: false, null: false)
      add(:is_disabled, :boolean, default: false, null: false)
      add(:disabled_reason, :string)
      add(:synced_at, :timestamptz)
      add(:errored_at, :timestamptz)
      add(:error_message, :text)
      add(:error_email_count, :integer, default: 0, null: false)
      timestamps()
    end

    create(unique_index(:sophos_posture_providers, [:account_id, :tenant_id]))

    create table(:sophos_devices, primary_key: false) do
      add(:account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        null: false,
        primary_key: true
      )

      add(:sophos_id, :string, null: false, primary_key: true)

      add(
        :posture_provider_id,
        references(:posture_providers,
          column: :id,
          with: [account_id: :account_id],
          type: :binary_id,
          on_delete: :delete_all
        ),
        null: false
      )

      # Endpoint object, Endpoint API v1 `GET /endpoints?view=full`.
      add(:type, :string)
      add(:sophos_tenant_id, :string)
      add(:hostname, :string)
      add(:health_overall, :string)
      add(:health_threats_status, :string)
      add(:health_services_status, :string)
      add(:health_service_details, :map)
      add(:os_is_server, :boolean)
      add(:os_platform, :string)
      add(:os_name, :string)
      add(:os_major_version, :integer)
      add(:os_minor_version, :integer)
      add(:os_build, :integer)
      add(:ipv4_addresses, {:array, :string})
      add(:ipv6_addresses, {:array, :string})
      add(:mac_addresses, {:array, :string})
      add(:group_id, :string)
      add(:group_name, :string)
      add(:group_hierarchy, :map)
      add(:associated_person_id, :string)
      add(:associated_person_name, :string)
      add(:associated_person_via_login, :string)
      add(:tamper_protection_supported, :boolean)
      add(:tamper_protection_enabled, :boolean)
      add(:assigned_products, :map)
      add(:packages, :map)
      add(:device_software, :map)
      add(:last_seen_at, :timestamptz)
      add(:last_os_update_at, :timestamptz)
      add(:last_agent_update_at, :timestamptz)
      # Not every endpoint reports one; Linux endpoints often do not.
      add(:serial_number, :string)
      add(:encryption_overall_status, :string)
      add(:encryption_volumes, :map)
      add(:lockdown_status, :string)
      add(:tags, :map)
      add(:online, :boolean)
      add(:cloud_provider, :string)
      add(:cloud_instance_id, :string)
      add(:isolation_status, :string)
      add(:isolation_admin_isolated, :boolean)
      add(:isolation_self_isolated, :boolean)
      add(:cloned, :boolean)

      add(:synced_at, :timestamptz, null: false)
      timestamps()
    end

    create(index(:sophos_devices, [:account_id, :inserted_at, :sophos_id]))

    create(
      index(:sophos_devices, [:account_id, :posture_provider_id, :synced_at],
        name: :sophos_devices_provider_synced_at_index
      )
    )
  end

  def down do
    drop(table(:sophos_devices))
    drop(table(:sophos_posture_providers))

    drop(constraint(:posture_providers, :type_must_be_valid))
    execute("DELETE FROM posture_providers WHERE type = 'sophos'")

    create(
      constraint(:posture_providers, :type_must_be_valid,
        check: "type IN ('intune', 'iru', 'defender', 'santa', 'sentinelone')"
      )
    )
  end
end
