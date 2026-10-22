defmodule Portal.Repo.Migrations.RemoveClientToClientFeature do
  use Ecto.Migration

  def up do
    execute("DELETE FROM features WHERE feature = 'client_to_client'")

    execute("""
    UPDATE accounts
    SET features = features - 'client_to_client'
    WHERE features ? 'client_to_client'
    """)
  end

  # Restores the global flag only. Which accounts had the per-account feature is
  # not recoverable, and every account is entitled to device pools now anyway.
  def down do
    execute("INSERT INTO features (feature, enabled) VALUES ('client_to_client', true)")
  end
end
