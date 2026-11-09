defmodule Portal.Repo.Migrations.ValidateDevicesGatewayTokenFkey do
  use Ecto.Migration

  @disable_ddl_transaction true

  def up do
    execute("ALTER TABLE devices VALIDATE CONSTRAINT devices_gateway_token_id_fkey")
  end

  def down, do: :ok
end
