defmodule Portal.Repo.Migrations.DropExpiresAtFromFlows do
  use Ecto.Migration

  def up do
    alter table(:flows) do
      remove(:expires_at)
    end
  end

  def down do
    alter table(:flows) do
      add(:expires_at, :utc_datetime_usec, null: false)
    end
  end
end
