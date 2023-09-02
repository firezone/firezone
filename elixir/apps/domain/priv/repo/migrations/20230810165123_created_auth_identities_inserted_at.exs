defmodule Domain.Repo.Migrations.CreatedAuthIdentitiesInsertedAt do
  use Ecto.Migration

  def change do
    alter table(:auth_identities) do
      timestamps(updated_at: false)
    end
  end
end
