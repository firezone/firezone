defmodule Portal.Repo.Migrations.CreateSantaDeviceInventory do
  use Ecto.Migration

  def up do
    drop(constraint(:posture_providers, :type_must_be_valid))

    create(
      constraint(:posture_providers, :type_must_be_valid,
        check: "type IN ('intune', 'iru', 'defender', 'santa')"
      )
    )

    create table(:santa_posture_providers, primary_key: false) do
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

      add(:api_url, :string, null: false)
      add(:api_key, :string, null: false)

      add(:is_verified, :boolean, default: false, null: false)
      add(:is_disabled, :boolean, default: false, null: false)
      add(:disabled_reason, :string)
      add(:synced_at, :timestamptz)
      add(:errored_at, :timestamptz)
      add(:error_message, :text)
      add(:error_email_count, :integer, default: 0, null: false)
      timestamps()
    end

    create(unique_index(:santa_posture_providers, [:account_id, :api_url]))

    create table(:santa_devices, primary_key: false) do
      add(:account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        null: false,
        primary_key: true
      )

      # Workshop calls this the host UUID, although the API explicitly permits
      # clients to report an identifier that is not a UUID.
      add(:santa_id, :string, null: false, primary_key: true)

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

      # workshop.v1.Host
      add(:serial_number, :citext)
      add(:machine_model, :string)
      add(:hostname, :string)
      add(:os_version, :string)
      add(:os_build, :string)
      add(:os_type, :string)
      # The API defines this as uint32, so use bigint rather than Postgres's
      # signed 32-bit integer even though current SIP status values are small.
      add(:sip_status, :bigint)
      add(:primary_user, :string)
      add(:primary_user_locked, :boolean)
      add(:primary_user_groups, {:array, :string})
      add(:santa_version, :string)
      add(:santanetd_version, :string)
      add(:last_seen_client_mode, :string)
      add(:last_sync_at, :timestamptz)
      add(:rule_sync_at, :timestamptz)
      add(:last_preflight_at, :timestamptz)
      # workshop.v1.Host defines this as bytes. ProtoJSON sends those bytes as
      # base64, which is preserved so the REST API can expose format: byte.
      add(:last_preflight_ip, :string)
      add(:tags, {:array, :string})
      add(:tags_locked, :boolean)
      add(:tags_truncated, :boolean)

      # These fields are normally populated only by GetHost. Keeping columns
      # for them makes the inventory forward-compatible if ListHosts includes
      # them for a Workshop deployment.
      add(:configured_client_mode, :string)
      add(:temporary_monitor_mode_ends_at, :timestamptz)
      add(:first_seen_at, :timestamptz)
      add(:temporary_admin_mode_ends_at, :timestamptz)
      add(:temporary_admin_mode_user, :string)

      add(:synced_at, :timestamptz, null: false)

      timestamps()
    end

    create(index(:santa_devices, [:account_id, :inserted_at, :santa_id]))

    create(
      index(:santa_devices, [:account_id, :posture_provider_id, :synced_at],
        name: :santa_devices_provider_synced_at_index
      )
    )
  end

  def down do
    drop(table(:santa_devices))
    drop(table(:santa_posture_providers))

    drop(constraint(:posture_providers, :type_must_be_valid))
    execute("DELETE FROM posture_providers WHERE type = 'santa'")

    create(
      constraint(:posture_providers, :type_must_be_valid,
        check: "type IN ('intune', 'iru', 'defender')"
      )
    )
  end
end
