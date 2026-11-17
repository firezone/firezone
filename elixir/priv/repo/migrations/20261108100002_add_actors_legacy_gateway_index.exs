defmodule Portal.Repo.Migrations.AddActorsLegacyGatewayIndex do
  use Ecto.Migration

  @disable_ddl_transaction true

  # One legacy Gateway actor per account, whatever path inserts it.
  def up do
    create_if_not_exists(
      unique_index(:actors, [:account_id],
        where: "type = 'legacy_gateway'",
        name: :actors_account_id_legacy_gateway_index,
        concurrently: true
      )
    )
  end

  def down do
    drop_if_exists(
      index(:actors, [:account_id],
        name: :actors_account_id_legacy_gateway_index,
        concurrently: true
      )
    )
  end
end
