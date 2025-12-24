defmodule Portal.Repo.Migrations.AddDefaultToAuthProviders do
  use Ecto.Migration

  @disable_ddl_transaction true

  def up do
    alter table(:auth_providers) do
      add(:assigned_default_at, :utc_datetime_usec)
    end

    create(
      index(:auth_providers, :account_id,
        name: :auth_providers_account_id_assigned_default_at_index,
        unique: true,
        where: "deleted_at IS NULL AND disabled_at IS NULL AND assigned_default_at IS NOT NULL",
        concurrently: true
      )
    )
  end

  def down do
    drop(
      index(:auth_providers, :account_id,
        name: :auth_providers_account_id_assigned_default_at_index,
        unique: true,
        where: "deleted_at IS NULL AND disabled_at IS NULL AND assigned_default_at IS NOT NULL",
        concurrently: true
      )
    )

    alter table(:auth_providers) do
      remove(:assigned_default_at)
    end
  end
end
