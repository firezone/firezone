defmodule Portal.Repo.Migrations.CreateDefenderDeviceInventory do
  use Ecto.Migration

  def up do
    drop(constraint(:posture_providers, :type_must_be_valid))

    create(
      constraint(:posture_providers, :type_must_be_valid,
        check: "type IN ('intune', 'iru', 'defender')"
      )
    )

    create table(:defender_posture_providers, primary_key: false) do
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

      add(:tenant_id, :string, null: false)

      add(:is_verified, :boolean, default: false, null: false)
      add(:is_disabled, :boolean, default: false, null: false)
      add(:disabled_reason, :string)
      add(:synced_at, :timestamptz)
      add(:errored_at, :timestamptz)
      add(:error_message, :text)
      add(:error_email_count, :integer, default: 0, null: false)
      timestamps()
    end

    create(unique_index(:defender_posture_providers, [:account_id, :tenant_id]))

    create table(:defender_devices, primary_key: false) do
      add(:account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        null: false,
        primary_key: true
      )

      # Defender's machine id. Unique per tenant and stable for the life of the
      # onboarding, so it is the key rather than an id of our own.
      add(:defender_id, :string, null: false, primary_key: true)

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

      add(:computer_dns_name, :string)
      add(:entra_device_id, :string)
      add(:entra_joined, :boolean)
      add(:machine_tags, {:array, :string})

      # Operating system
      add(:os_platform, :string)
      add(:version, :string)
      add(:os_build, :bigint)
      add(:os_processor, :string)
      add(:os_architecture, :string)

      # Network
      add(:last_ip_address, :string)
      add(:last_external_ip_address, :string)

      # Sensor and management
      add(:agent_version, :string)
      add(:health_status, :string)
      add(:onboarding_status, :string)
      add(:managed_by, :string)
      add(:managed_by_status, :string)

      # Posture
      add(:risk_score, :string)
      add(:exposure_level, :string)
      add(:device_value, :string)

      # Device groups
      add(:rbac_group_id, :string)
      add(:rbac_group_name, :string)

      # Duplicate and exclusion bookkeeping
      add(:is_potential_duplication, :boolean)
      add(:merged_into_machine_id, :string)
      add(:is_excluded, :boolean)
      add(:exclusion_reason, :text)

      # Azure virtual machine, flattened from the `vmMetadata` object
      add(:vm_id, :string)
      add(:vm_cloud_provider, :string)
      add(:vm_resource_id, :text)
      add(:vm_subscription_id, :string)

      # ipAddresses is the one collection-valued property that is not a plain
      # list of strings, so it cannot become a column of its own. `:map` is
      # jsonb, which stores the JSON array the schema reads back as
      # {:array, :map}. Declaring the array type here would give jsonb[], which
      # is not the same.
      add(:ip_addresses, :map)

      add(:first_seen_at, :timestamptz)
      add(:last_seen_at, :timestamptz)
      add(:synced_at, :timestamptz, null: false)

      timestamps()
    end

    # Matches the REST list endpoint's cursor order so a page is an index range
    # scan rather than a sort of the whole account.
    create(index(:defender_devices, [:account_id, :inserted_at, :defender_id]))

    create(
      index(:defender_devices, [:account_id, :posture_provider_id, :synced_at],
        name: :defender_devices_provider_synced_at_index
      )
    )
  end

  def down do
    drop(table(:defender_devices))
    drop(table(:defender_posture_providers))

    # The shared rows outlive the table they point at, and the type constraint
    # restored below does not allow them.
    execute("DELETE FROM posture_providers WHERE type = 'defender'")

    drop(constraint(:posture_providers, :type_must_be_valid))

    create(
      constraint(:posture_providers, :type_must_be_valid, check: "type IN ('intune', 'iru')")
    )
  end
end
