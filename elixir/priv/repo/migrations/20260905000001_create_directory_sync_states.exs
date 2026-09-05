defmodule Portal.Repo.Migrations.CreateDirectorySyncStates do
  use Ecto.Migration

  @tables [
    {:directory_identity_sync_states, :external_identity_sync_states, :external_identities,
     :external_identity_id},
    {:directory_group_sync_states, :group_sync_states, :groups, :group_id}
  ]

  def up do
    for {table, old_table, entity_table, entity_fk} <- @tables do
      create_if_not_exists table(table, primary_key: false) do
        add(:account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
          null: false,
          primary_key: true
        )

        add(
          :directory_id,
          references(:directories,
            type: :binary_id,
            on_delete: :delete_all,
            with: [account_id: :account_id]
          ),
          null: false,
          primary_key: true
        )

        add(:idp_id, :text, null: false, primary_key: true)
        add(:synced_at, :timestamptz, null: false)
        add(:memberships_synced_at, :timestamptz)
      end

      execute("""
      INSERT INTO #{table} (account_id, directory_id, idp_id, synced_at)
      SELECT s.account_id, e.directory_id, e.idp_id, s.synced_at
      FROM #{old_table} s
      JOIN #{entity_table} e ON e.account_id = s.account_id AND e.id = s.#{entity_fk}
      WHERE e.directory_id IS NOT NULL AND e.idp_id IS NOT NULL AND s.synced_at IS NOT NULL
      ON CONFLICT DO NOTHING
      """)
    end
  end

  def down do
    for {table, _old_table, _entity_table, _entity_fk} <- @tables do
      drop_if_exists(table(table))
    end
  end
end
