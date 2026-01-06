defmodule Portal.Repo.Migrations.DeleteEveryoneGroupMemberships do
  use Ecto.Migration

  def change do
    execute(
      """
      DELETE FROM actor_group_memberships
      WHERE group_id IN (
        SELECT id FROM actor_groups
        WHERE type = 'managed'
          AND idp_id IS NULL
          AND name = 'Everyone'
      )
      """,
      # Rollback: no-op, we can't restore deleted memberships
      ""
    )
  end
end
