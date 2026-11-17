defmodule Portal.Repo.Migrations.CreateAccountSlugs do
  use Ecto.Migration

  def up do
    create table(:account_slugs, primary_key: false) do
      add :slug, :citext, primary_key: true
      add :account_id, references(:accounts, type: :uuid, on_delete: :delete_all), null: false
      add :inserted_at, :timestamptz, null: false
    end

    create_if_not_exists index(:account_slugs, [:account_id])

    execute("""
    INSERT INTO account_slugs (slug, account_id, inserted_at)
    SELECT slug, id, inserted_at
    FROM accounts
    WHERE slug IS NOT NULL
    """)
  end

  def down do
    drop_if_exists index(:account_slugs, [:account_id])
    drop table(:account_slugs)
  end
end
