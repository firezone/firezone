defmodule Portal.Repo.Migrations.ChangeUsersEmailToCitext do
  use Ecto.Migration

  def change do
    execute("CREATE EXTENSION IF NOT EXISTS citext")

    alter table(:users) do
      modify(:email, :citext)
    end
  end
end
