defmodule Portal.Repo.Migrations.RemoveDeletedAtFromTokens do
  use Ecto.Migration

  def change do
    alter table(:tokens) do
      remove(:deleted_at, :utc_datetime_usec)
    end
  end
end
