defmodule Portal.Repo.Migrations.AddMetersToAccounts do
  use Ecto.Migration

  def change do
    alter table(:accounts) do
      add(:meters, {:array, :string}, null: true)
    end
  end
end
