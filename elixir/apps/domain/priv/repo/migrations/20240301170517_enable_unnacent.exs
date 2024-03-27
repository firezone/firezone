defmodule Domain.Repo.Migrations.EnableUnnacent do
  use Ecto.Migration

  def change do
    execute("""
    CREATE EXTENSION unaccent;
    """)
  end
end
