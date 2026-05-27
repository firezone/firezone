defmodule Portal.Repo.Migrations.MoveSyncedAtToStateTables do
  use Ecto.Migration

  def up do
    # Create the sync state tables (not added to the replication publication,
    # so updates don't generate WAL noise in the changelog).
    # Composite FKs on (account_id, entity_id) prevent sync state from hopping accounts.
    create_if_not_exists table(:group_sync_states, primary_key: false) do
      add(:account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        null: false,
        primary_key: true
      )

      add(
        :group_id,
        references(:groups,
          type: :binary_id,
          with: [account_id: :account_id],
          on_delete: :delete_all
        ),
        null: false,
        primary_key: true
      )

      add(:synced_at, :utc_datetime_usec)
    end

    create_if_not_exists table(:external_identity_sync_states, primary_key: false) do
      add(:account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        null: false,
        primary_key: true
      )

      add(
        :external_identity_id,
        references(:external_identities,
          type: :binary_id,
          with: [account_id: :account_id],
          on_delete: :delete_all
        ),
        null: false,
        primary_key: true
      )

      add(:synced_at, :utc_datetime_usec)
    end

    create_if_not_exists table(:membership_sync_states, primary_key: false) do
      add(:account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        null: false,
        primary_key: true
      )

      add(
        :membership_id,
        references(:memberships,
          type: :binary_id,
          with: [account_id: :account_id],
          on_delete: :delete_all
        ),
        null: false,
        primary_key: true
      )

      add(:synced_at, :utc_datetime_usec)
    end

    # synced_at index to efficiently filter stale records.
    create_if_not_exists(index(:group_sync_states, [:synced_at]))
    create_if_not_exists(index(:external_identity_sync_states, [:synced_at]))
    create_if_not_exists(index(:membership_sync_states, [:synced_at]))

    # Migrate existing data from main tables to state tables
    execute("""
    INSERT INTO group_sync_states (account_id, group_id, synced_at)
    SELECT account_id, id, last_synced_at
    FROM groups
    WHERE last_synced_at IS NOT NULL
    ON CONFLICT (account_id, group_id) DO NOTHING
    """)

    execute("""
    INSERT INTO external_identity_sync_states (account_id, external_identity_id, synced_at)
    SELECT account_id, id, last_synced_at
    FROM external_identities
    WHERE last_synced_at IS NOT NULL
    ON CONFLICT (account_id, external_identity_id) DO NOTHING
    """)

    execute("""
    INSERT INTO membership_sync_states (account_id, membership_id, synced_at)
    SELECT account_id, id, last_synced_at
    FROM memberships
    WHERE last_synced_at IS NOT NULL
    ON CONFLICT (account_id, membership_id) DO NOTHING
    """)

    # Remove last_synced_at columns from main tables
    # (indexes on dropped columns are cleaned up automatically)
    alter table(:groups) do
      remove_if_exists(:last_synced_at, :utc_datetime_usec)
    end

    alter table(:external_identities) do
      remove_if_exists(:last_synced_at, :utc_datetime_usec)
    end

    alter table(:memberships) do
      remove_if_exists(:last_synced_at, :utc_datetime_usec)
    end
  end

  def down do
    # Re-add columns to main tables
    alter table(:groups) do
      add_if_not_exists(:last_synced_at, :utc_datetime_usec)
    end

    alter table(:external_identities) do
      add_if_not_exists(:last_synced_at, :utc_datetime_usec)
    end

    alter table(:memberships) do
      add_if_not_exists(:last_synced_at, :utc_datetime_usec)
    end

    # Restore data from state tables back to main tables
    execute("""
    UPDATE groups g
    SET last_synced_at = gss.synced_at
    FROM group_sync_states gss
    WHERE gss.account_id = g.account_id
      AND gss.group_id = g.id
    """)

    execute("""
    UPDATE external_identities ei
    SET last_synced_at = iss.synced_at
    FROM external_identity_sync_states iss
    WHERE iss.account_id = ei.account_id
      AND iss.external_identity_id = ei.id
    """)

    execute("""
    UPDATE memberships m
    SET last_synced_at = mss.synced_at
    FROM membership_sync_states mss
    WHERE mss.account_id = m.account_id
      AND mss.membership_id = m.id
    """)

    # Re-create old indexes on main tables
    create_if_not_exists(
      index(:groups, [:last_synced_at],
        name: :groups_last_synced_at_index,
        where: "last_synced_at IS NOT NULL"
      )
    )

    create_if_not_exists(
      index(:memberships, [:last_synced_at],
        name: :memberships_last_synced_at_index,
        where: "last_synced_at IS NOT NULL"
      )
    )

    # Drop state tables (constraints and indexes are dropped automatically)
    drop_if_exists(table(:membership_sync_states))
    drop_if_exists(table(:external_identity_sync_states))
    drop_if_exists(table(:group_sync_states))
  end
end
