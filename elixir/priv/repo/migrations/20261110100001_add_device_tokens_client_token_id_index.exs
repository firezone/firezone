defmodule Portal.Repo.Migrations.AddDeviceTokensClientTokenIdIndex do
  use Ecto.Migration

  @disable_ddl_transaction true

  def change do
    create_if_not_exists(
      index(:device_tokens, [:account_id, :client_token_id],
        where: "client_token_id IS NOT NULL",
        concurrently: true
      )
    )
  end
end
