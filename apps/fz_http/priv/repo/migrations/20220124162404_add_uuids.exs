defmodule FzHttp.Repo.Migrations.AddUuids do
  use Ecto.Migration

  def change do
    execute(
      "CREATE EXTENSION IF NOT EXISTS pgcrypto",
      "DROP EXTENSION pgcrypto"
    )

    execute(
      "ALTER TABLE rules ADD COLUMN uuid uuid DEFAULT gen_random_uuid() NOT NULL",
      "ALTER TABLE rules DROP COLUMN uuid"
    )

    execute(
      "ALTER TABLE devices ADD COLUMN uuid uuid DEFAULT gen_random_uuid() NOT NULL",
      "ALTER TABLE devices DROP COLUMN uuid"
    )

    execute(
      "ALTER TABLE users ADD COLUMN uuid uuid DEFAULT gen_random_uuid() NOT NULL",
      "ALTER TABLE users DROP COLUMN uuid"
    )

    create unique_index(:rules, :uuid)
    create unique_index(:devices, :uuid)
    create unique_index(:users, :uuid)
  end
end
