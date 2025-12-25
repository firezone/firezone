defmodule Portal.Repo.Migrations.DropBrowserAndUserClientTokens do
  use Ecto.Migration

  def up do
    execute("""
    DELETE FROM tokens
    USING actors
    WHERE tokens.actor_id = actors.id
      AND actors.type IN ('account_user', 'account_admin_user')
    """)
  end

  def down do
    # Tokens cannot be recovered once deleted
    :ok
  end
end
