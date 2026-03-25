defmodule Portal.Repo.Migrations.AddKeyToAccounts do
  use Ecto.Migration

  def change do
    alter table(:accounts) do
      add(:key, :string, size: 6)
    end
  end
end
