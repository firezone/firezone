defmodule Portal.Repo.Migrations.DropEntityKeyedSyncStates do
  @moduledoc """
  Drops external_identity_sync_states and group_sync_states after their rows
  were copied to the directory-keyed tables (see CreateDirectorySyncStates).

  Manual on purpose: run only after the release that stops reading and
  writing the old tables is fully rolled out, since old nodes still write
  to them during the rollout.
  """
  use Ecto.Migration

  def up do
    drop_if_exists(table(:external_identity_sync_states))
    drop_if_exists(table(:group_sync_states))
  end

  def down do
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

      add(:synced_at, :timestamptz)
    end

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

      add(:synced_at, :timestamptz)
    end

    create_if_not_exists(index(:external_identity_sync_states, [:synced_at]))
    create_if_not_exists(index(:group_sync_states, [:synced_at]))
  end
end
