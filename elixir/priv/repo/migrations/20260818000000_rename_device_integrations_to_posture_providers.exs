defmodule Portal.Repo.Migrations.RenameDeviceIntegrationsToPostureProviders do
  use Ecto.Migration

  def up do
    rename(table(:device_integrations), to: table(:posture_providers))
    rename(table(:intune_integrations), to: table(:intune_posture_providers))
    rename(table(:intune_devices), :device_integration_id, to: :posture_provider_id)

    execute("ALTER INDEX device_integrations_pkey RENAME TO posture_providers_pkey")

    execute("ALTER INDEX intune_integrations_pkey RENAME TO intune_posture_providers_pkey")

    execute("ALTER TABLE posture_providers RENAME CONSTRAINT device_integrations_account_id_fkey TO posture_providers_account_id_fkey")

    execute("ALTER TABLE intune_posture_providers RENAME CONSTRAINT intune_integrations_account_id_fkey TO intune_posture_providers_account_id_fkey")

    execute("ALTER TABLE intune_posture_providers RENAME CONSTRAINT intune_integrations_id_fkey TO intune_posture_providers_id_fkey")

    execute("ALTER TABLE intune_devices RENAME CONSTRAINT intune_devices_device_integration_id_fkey TO intune_devices_posture_provider_id_fkey")

    # An account may now connect more than one provider of the same type, so the
    # type alone no longer identifies a row. Each provider type gets a uniqueness
    # rule over the identifier of the remote tenant instead.
    drop_if_exists(
      index(:posture_providers, [:account_id, :type],
        name: :device_integrations_account_id_type_index
      )
    )

    drop(constraint(:posture_providers, :type_must_be_valid))

    create(
      constraint(:posture_providers, :type_must_be_valid,
        check: "type IN ('intune', 'iru')"
      )
    )

    create_if_not_exists(unique_index(:intune_posture_providers, [:account_id, :tenant_id]))

    # The name labels the provider to an admin whatever its type, so it lives on
    # the shared row and is unique across the account rather than per type.
    alter table(:posture_providers) do
      add(:name, :string)
    end

    execute("""
    UPDATE posture_providers AS p
    SET name = i.name
    FROM intune_posture_providers AS i
    WHERE i.account_id = p.account_id AND i.id = p.id
    """)

    alter table(:posture_providers) do
      modify(:name, :string, null: false)
    end

    create_if_not_exists(unique_index(:posture_providers, [:account_id, :name]))

    alter table(:intune_posture_providers) do
      remove(:name)
    end

    drop_if_exists(
      index(:intune_devices, [:account_id, :posture_provider_id, :synced_at],
        name: :intune_devices_account_id_device_integration_id_synced_at_index
      )
    )

    create_if_not_exists(
      index(:intune_devices, [:account_id, :posture_provider_id, :synced_at],
        name: :intune_devices_provider_synced_at_index
      )
    )
  end

  def down do
    drop_if_exists(
      index(:intune_devices, [:account_id, :posture_provider_id, :synced_at],
        name: :intune_devices_provider_synced_at_index
      )
    )

    create_if_not_exists(
      index(:intune_devices, [:account_id, :posture_provider_id, :synced_at],
        name: :intune_devices_account_id_device_integration_id_synced_at_index
      )
    )

    alter table(:intune_posture_providers) do
      add(:name, :string)
    end

    execute("""
    UPDATE intune_posture_providers AS i
    SET name = p.name
    FROM posture_providers AS p
    WHERE i.account_id = p.account_id AND i.id = p.id
    """)

    alter table(:intune_posture_providers) do
      modify(:name, :string, null: false)
    end

    drop_if_exists(unique_index(:posture_providers, [:account_id, :name]))

    alter table(:posture_providers) do
      remove(:name)
    end

    create_if_not_exists(unique_index(:intune_posture_providers, [:account_id, :name]))
    drop_if_exists(unique_index(:intune_posture_providers, [:account_id, :tenant_id]))

    drop(constraint(:posture_providers, :type_must_be_valid))

    create(
      constraint(:posture_providers, :type_must_be_valid, check: "type IN ('intune')")
    )

    create_if_not_exists(
      unique_index(:posture_providers, [:account_id, :type],
        name: :device_integrations_account_id_type_index
      )
    )

    execute("ALTER TABLE intune_devices RENAME CONSTRAINT intune_devices_posture_provider_id_fkey TO intune_devices_device_integration_id_fkey")

    execute("ALTER TABLE intune_posture_providers RENAME CONSTRAINT intune_posture_providers_id_fkey TO intune_integrations_id_fkey")

    execute("ALTER TABLE intune_posture_providers RENAME CONSTRAINT intune_posture_providers_account_id_fkey TO intune_integrations_account_id_fkey")

    execute("ALTER TABLE posture_providers RENAME CONSTRAINT posture_providers_account_id_fkey TO device_integrations_account_id_fkey")

    execute("ALTER INDEX intune_posture_providers_pkey RENAME TO intune_integrations_pkey")

    execute("ALTER INDEX posture_providers_pkey RENAME TO device_integrations_pkey")

    rename(table(:intune_devices), :posture_provider_id, to: :device_integration_id)
    rename(table(:intune_posture_providers), to: table(:intune_integrations))
    rename(table(:posture_providers), to: table(:device_integrations))
  end
end
