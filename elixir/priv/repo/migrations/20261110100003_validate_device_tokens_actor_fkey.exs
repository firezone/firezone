defmodule Portal.Repo.Migrations.ValidateDeviceTokensActorFkey do
  use Ecto.Migration

  @disable_ddl_transaction true

  def up do
    execute("ALTER TABLE device_tokens VALIDATE CONSTRAINT device_tokens_actor_id_fkey")
  end

  def down, do: :ok
end
