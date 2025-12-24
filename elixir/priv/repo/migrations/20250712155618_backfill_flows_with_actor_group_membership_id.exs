defmodule Portal.Repo.Migrations.BackfillFlowsWithActorGroupMembershipId do
  use Ecto.Migration

  @moduledoc """
  This migration will lock the `flows` table, so it's best to run this when a brief period of
  downtime is acceptable.
  """

  def up do
    # Step 1: Truncate flows table to remove entries older than 14 days
    execute("""
    DELETE FROM flows
    WHERE inserted_at < NOW() - INTERVAL '14 days'
    """)

    # Step 2: Add the new foreign key column if it doesn't already exist
    execute("""
    ALTER TABLE flows
    ADD COLUMN IF NOT EXISTS actor_group_membership_id UUID
    """)

    # Step 3: Backfill the new column by finding the correct membership ID
    execute("""
    UPDATE flows AS f
    SET actor_group_membership_id = agm.id
    FROM
      clients AS c,
      policies AS p,
      actor_group_memberships AS agm
    WHERE
      f.client_id = c.id
      AND f.policy_id = p.id
      AND c.actor_id = agm.actor_id
      AND p.actor_group_id = agm.group_id
    """)

    # Step 4: Delete flow records where a membership couldn't be found
    execute("""
    DELETE FROM flows
    WHERE actor_group_membership_id IS NULL
    """)

    # Step 5: Now that all rows are populated, make the column NOT NULL
    execute("""
    ALTER TABLE flows
    ALTER COLUMN actor_group_membership_id SET NOT NULL
    """)

    # Step 6: Add an index on the new foreign key for performance
    execute("""
    CREATE INDEX IF NOT EXISTS flows_actor_group_membership_id_index
    ON flows USING BTREE (account_id, actor_group_membership_id, inserted_at DESC, id DESC)
    """)

    # Step 7: Add the foreign key constraint
    execute("""
    ALTER TABLE flows
    ADD CONSTRAINT flows_actor_group_membership_id_fkey
    FOREIGN KEY (actor_group_membership_id)
    REFERENCES actor_group_memberships(id)
    ON DELETE CASCADE
    """)
  end

  def down do
    # Step 1: Drop the foreign key constraint
    execute("""
    ALTER TABLE flows
    DROP CONSTRAINT IF EXISTS flows_actor_group_membership_id_fkey
    """)

    # Step 2: Drop the index
    execute("""
    DROP INDEX IF EXISTS flows_actor_group_membership_id_index
    """)

    # Step 3: Drop the column
    execute("""
    ALTER TABLE flows
    DROP COLUMN IF EXISTS actor_group_membership_id
    """)

    # Note: The data deleted in the 'up' migration is not restored.
  end
end
