defmodule Portal.Repo.Migrations.AddDevicesTokenIdIndex do
  use Ecto.Migration

  @disable_ddl_transaction true

  def change do
    create_if_not_exists(
      index(:devices, [:account_id, :token_id],
        where: "token_id IS NOT NULL",
        concurrently: true
      )
    )
  end
end
