defmodule Portal.Repo.Migrations.AddIsDisabledToAccounts do
  use Ecto.Migration

  def up do
    alter table(:accounts) do
      add(:is_disabled, :boolean, default: false, null: false)
    end

    execute("UPDATE accounts SET is_disabled = true WHERE disabled_at IS NOT NULL")
  end

  def down do
    alter table(:accounts) do
      remove(:is_disabled)
    end
  end
end
