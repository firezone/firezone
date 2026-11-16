defmodule Portal.Repo.Migrations.AddDevicesGatewayFirezoneIdIndex do
  use Ecto.Migration

  @disable_ddl_transaction true

  def change do
    create_if_not_exists(
      unique_index(:devices, [:account_id, :firezone_id],
        where: "type = 'gateway' AND NOT firezone_id_exempt",
        concurrently: true
      )
    )
  end
end
