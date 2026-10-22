defmodule Portal.Repo.Migrations.AddDevicesTokenIndexes do
  @moduledoc """
  Indexes the devices token columns for the token-list preloads and
  gateway-token rotation checks that previously used the session tables'
  token indexes. Separate from CollapseDeviceSessions so its backfill runs
  without maintaining these indexes.
  """
  use Ecto.Migration

  @disable_ddl_transaction true

  def change do
    create_if_not_exists(
      index(:devices, [:account_id, :client_token_id],
        where: "client_token_id IS NOT NULL",
        concurrently: true
      )
    )

    create_if_not_exists(
      index(:devices, [:account_id, :gateway_token_id],
        where: "gateway_token_id IS NOT NULL",
        concurrently: true
      )
    )
  end
end
