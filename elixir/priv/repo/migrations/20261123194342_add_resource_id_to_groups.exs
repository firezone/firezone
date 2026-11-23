defmodule Portal.Repo.Migrations.AddResourceIdToGroups do
  @moduledoc """
  A group with a `resource_id` holds the people given access to that one
  resource directly, without an admin-made group. Deleting the resource deletes
  the group, and with it its memberships and its policy.
  """
  use Ecto.Migration

  def up do
    execute("SET LOCAL lock_timeout TO '2s'")

    alter table(:groups) do
      add_if_not_exists(:resource_id, :binary_id)
    end

    execute("""
    ALTER TABLE groups
      ADD CONSTRAINT groups_resource_id_fkey
      FOREIGN KEY (account_id, resource_id) REFERENCES resources(account_id, id)
      ON DELETE CASCADE
    """)
  end

  def down do
    execute("SET LOCAL lock_timeout TO '2s'")
    execute("ALTER TABLE groups DROP CONSTRAINT IF EXISTS groups_resource_id_fkey")

    alter table(:groups) do
      remove_if_exists(:resource_id, :binary_id)
    end
  end
end
