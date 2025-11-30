defmodule Domain.Repo.Migrations.RemoveRelayGroupsAndSimplifyRelays do
  use Ecto.Migration

  def change do
    # Update token types from relay_group to relay
    execute(
      """
      UPDATE tokens 
      SET type = 'relay' 
      WHERE type = 'relay_group'
      """,
      """
      UPDATE tokens 
      SET type = 'relay_group' 
      WHERE type = 'relay'
      """
    )

    # Drop the foreign key constraint from tokens table
    alter table(:tokens) do
      remove(:relay_group_id)
    end

    # Remove group_id and account_id columns from relays table
    alter table(:relays) do
      remove(:group_id)
      remove(:account_id)
    end

    # Drop relay_groups table
    drop(table(:relay_groups))
  end
end
