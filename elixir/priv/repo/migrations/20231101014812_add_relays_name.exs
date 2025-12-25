defmodule Portal.Repo.Migrations.AddRelaysName do
  use Ecto.Migration

  def change do
    alter table(:relays) do
      add(:name, :string)
    end
  end
end
