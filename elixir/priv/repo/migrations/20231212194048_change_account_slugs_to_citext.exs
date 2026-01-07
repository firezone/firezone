defmodule Portal.Repo.Migrations.ChangeAccountSlugsToCitext do
  use Ecto.Migration

  def change do
    execute("CREATE EXTENSION IF NOT EXISTS citext")

    alter table(:accounts) do
      modify(:slug, :citext)
    end
  end
end
