defmodule Portal.Repo.Migrations.RemoveDeletedAtFromAuthIdentities do
  use Ecto.Migration

  def change do
    alter table(:auth_identities) do
      remove(:deleted_at, :utc_datetime_usec)
    end
  end
end
