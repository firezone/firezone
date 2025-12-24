defmodule Portal.Repo.Migrations.CreatedAuthIdentitiesInsertedAt do
  use Ecto.Migration

  def change do
    alter table(:auth_identities) do
      add(:inserted_at, :utc_datetime_usec, null: false, default: fragment("now()"))
    end
  end
end
