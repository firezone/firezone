defmodule Portal.Repo.Migrations.AddEmailToGroups do
  use Ecto.Migration

  def change do
    alter table(:groups) do
      add(:email, :string, null: true)
    end
  end
end
