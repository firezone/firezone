defmodule Portal.Repo.Migrations.IndexFlowsOnExpiresAt do
  use Ecto.Migration

  @disable_ddl_transaction true

  def change do
    create_if_not_exists(
      index(:flows, [:account_id, :expires_at, :gateway_id], concurrently: true)
    )
  end
end
