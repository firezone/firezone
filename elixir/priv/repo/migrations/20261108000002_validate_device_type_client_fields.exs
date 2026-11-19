defmodule Portal.Repo.Migrations.ValidateDeviceTypeClientFields do
  use Ecto.Migration

  def up do
    execute("ALTER TABLE devices VALIDATE CONSTRAINT device_type_client_fields")
  end

  def down, do: :ok
end
