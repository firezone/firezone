defmodule Portal.Repo.Migrations.AddAccountsLegalName do
  use Ecto.Migration

  def change do
    alter table(:accounts) do
      add(:legal_name, :string)
    end

    execute("UPDATE accounts SET legal_name = name")

    execute("ALTER TABLE accounts ALTER COLUMN legal_name SET NOT NULL")
  end
end
