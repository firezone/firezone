defmodule Portal.Repo.Migrations.ReindexFlowsOnExpiresAt do
  use Ecto.Migration

  @disable_ddl_transaction true

  def change do
    drop_if_exists(index(:flows, [:account_id, :expires_at, :gateway_id], concurrently: true))

    create_if_not_exists(
      index(:flows, [:expires_at, :account_id, :gateway_id], concurrently: true)
    )
  end
end
