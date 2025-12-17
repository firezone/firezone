defmodule Portal.Repo.Migrations.ChangeColumnNullFlowsExpiresAt do
  use Ecto.Migration

  def up do
    alter table(:flows) do
      modify(:expires_at, :utc_datetime_usec, null: true)
    end
  end

  def down do
    alter table(:flows) do
      modify(:expires_at, :utc_datetime_usec, null: false)
    end
  end
end
