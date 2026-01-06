defmodule Portal.Repo.Migrations.AddIdToActorGroupMemberships do
  use Ecto.Migration

  @moduledoc """
  This migration will lock the `actor_group_memberships` table, so it's
  best to run this when a brief period of downtime is acceptable.
  """

  def up do
    # Step 1: Add the new column with a default value
    execute("""
    ALTER TABLE actor_group_memberships
    ADD COLUMN IF NOT EXISTS id UUID DEFAULT uuid_generate_v4()
    """)

    # Step 2: Backfill the new column for existing rows
    execute("""
    UPDATE actor_group_memberships SET id = uuid_generate_v4() WHERE id IS NULL
    """)

    # Step 3: Enforce the NOT NULL constraint
    execute("""
    ALTER TABLE actor_group_memberships
    ALTER COLUMN id SET NOT NULL
    """)

    # Step 4: Drop the old composite primary key
    execute("""
    ALTER TABLE actor_group_memberships
    DROP CONSTRAINT IF EXISTS actor_group_memberships_pkey
    """)

    # Step 5: Add the new primary key on the id column
    execute("""
    ALTER TABLE actor_group_memberships
    ADD PRIMARY KEY (id)
    """)

    # Step 6: Recreate the actor_id, group_id index with unique constraint
    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS actor_group_memberships_actor_id_group_id_index
    ON actor_group_memberships (actor_id, group_id)
    """)
  end

  def down do
    # Step 1: Drop the unique index on actor_id and group_id
    execute("""
    DROP INDEX IF EXISTS actor_group_memberships_actor_id_group_id_index
    """)

    # Step 2: Drop the new single-column primary key
    execute("""
    ALTER TABLE actor_group_memberships
    DROP CONSTRAINT IF EXISTS actor_group_memberships_pkey
    """)

    # Step 3: Restore the original composite primary key
    execute("""
    ALTER TABLE actor_group_memberships
    ADD CONSTRAINT IF NOT EXISTS actor_group_memberships_pkey PRIMARY KEY (actor_id, group_id)
    """)

    # Step 4: Drop the id column
    execute("""
    ALTER TABLE actor_group_memberships
    DROP COLUMN IF EXISTS id
    """)
  end
end
