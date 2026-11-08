defmodule Portal.Repo.Migrations.AddActorsLegacyGatewayIndex do
  use Ecto.Migration

  # One legacy Gateway actor per account, whatever path inserts it.
  def change do
    create_if_not_exists(
      unique_index(:actors, [:account_id],
        where: "type = 'legacy_gateway'",
        name: :actors_account_id_legacy_gateway_index
      )
    )
  end
end
