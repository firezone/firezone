defmodule Domain.Repo.Migrations.AddCascadeDeleteToAuthTables do
  use Ecto.Migration

  @tables [:portal_sessions, :one_time_passcodes, :gateway_tokens]

  def up do
    for table <- @tables do
      execute("""
      ALTER TABLE #{table}
      DROP CONSTRAINT IF EXISTS #{table}_account_id_fkey
      """)

      execute("""
      ALTER TABLE #{table}
      ADD CONSTRAINT #{table}_account_id_fkey
      FOREIGN KEY (account_id)
      REFERENCES accounts(id)
      ON DELETE CASCADE
      """)
    end
  end

  def down do
    for table <- @tables do
      execute("""
      ALTER TABLE #{table}
      DROP CONSTRAINT IF EXISTS #{table}_account_id_fkey
      """)

      execute("""
      ALTER TABLE #{table}
      ADD CONSTRAINT #{table}_account_id_fkey
      FOREIGN KEY (account_id)
      REFERENCES accounts(id)
      ON DELETE NO ACTION
      """)
    end
  end
end
