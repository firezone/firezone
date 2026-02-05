defmodule Portal.Repo.Migrations.AddGroupIdpIdToPolicies do
  @moduledoc """
  Adds group_idp_id column to policies to preserve group reference during directory sync.

  When a group is deleted during sync, ON DELETE SET NULL will clear group_id,
  but group_idp_id is preserved. When the group is re-created with the same idp_id,
  the reconnection logic can restore the group_id reference.
  """
  use Ecto.Migration

  def up do
    # 1. Add group_idp_id column to store IDP reference
    alter table(:policies) do
      add(:group_idp_id, :text)
    end

    # 2. Populate from existing groups' idp_id values
    execute("""
      UPDATE policies p
      SET group_idp_id = g.idp_id
      FROM groups g
      WHERE p.account_id = g.account_id AND p.group_id = g.id
    """)

    # 3. Drop existing FK constraint
    execute("ALTER TABLE policies DROP CONSTRAINT policies_group_id_fkey")

    # 4. Make group_id nullable
    alter table(:policies) do
      modify(:group_id, :binary_id, null: true)
    end

    # 5. Re-add FK with ON DELETE SET NULL (only nullifies group_id, not account_id)
    execute("""
      ALTER TABLE policies ADD CONSTRAINT policies_group_id_fkey
      FOREIGN KEY (account_id, group_id) REFERENCES groups(account_id, id)
      ON DELETE SET NULL (group_id)
    """)

    # 6. Update unique constraint to handle NULL group_id
    # NULL values are excluded from uniqueness check
    drop_if_exists(
      index(:policies, [:account_id, :resource_id, :group_id],
        name: :policies_account_id_resource_id_group_id_index
      )
    )

    create(
      unique_index(:policies, [:account_id, :resource_id, :group_id],
        name: :policies_account_id_resource_id_group_id_index,
        where: "group_id IS NOT NULL"
      )
    )

    # 7. Index for efficient reconnection lookups
    create(
      index(:policies, [:account_id, :group_idp_id],
        name: :policies_account_id_group_idp_id_index,
        where: "group_idp_id IS NOT NULL"
      )
    )
  end

  def down do
    # Remove reconnection index
    drop_if_exists(
      index(:policies, [:account_id, :group_idp_id],
        name: :policies_account_id_group_idp_id_index
      )
    )

    # Restore original unique constraint
    drop_if_exists(
      index(:policies, [:account_id, :resource_id, :group_id],
        name: :policies_account_id_resource_id_group_id_index
      )
    )

    create(
      unique_index(:policies, [:account_id, :resource_id, :group_id],
        name: :policies_account_id_resource_id_group_id_index
      )
    )

    # Drop FK constraint
    execute("ALTER TABLE policies DROP CONSTRAINT policies_group_id_fkey")

    # Delete orphaned policies (required before making NOT NULL)
    execute("DELETE FROM policies WHERE group_id IS NULL")

    # Make group_id NOT NULL again
    alter table(:policies) do
      modify(:group_id, :binary_id, null: false)
    end

    # Re-add FK with CASCADE
    execute("""
      ALTER TABLE policies ADD CONSTRAINT policies_group_id_fkey
      FOREIGN KEY (account_id, group_id) REFERENCES groups(account_id, id)
      ON DELETE CASCADE
    """)

    # Remove group_idp_id column
    alter table(:policies) do
      remove(:group_idp_id)
    end
  end
end
