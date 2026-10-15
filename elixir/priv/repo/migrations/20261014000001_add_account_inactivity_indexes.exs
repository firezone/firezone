defmodule Portal.Repo.Migrations.AddAccountInactivityIndexes do
  use Ecto.Migration

  @disable_ddl_transaction true

  def change do
    create_if_not_exists(
      index(:accounts, [:last_active_at],
        where: "scheduled_deletion_at IS NULL",
        concurrently: true
      )
    )

    create_if_not_exists(
      index(:accounts, [:inactivity_reminded_at],
        where: "inactivity_reminded_at IS NOT NULL",
        concurrently: true
      )
    )
  end
end
