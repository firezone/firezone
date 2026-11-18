defmodule Portal.Repo.Migrations.DropDevicesOldTokenColumns do
  use Ecto.Migration

  # Dropping each column also drops its foreign key and index.
  def up do
    execute("SET LOCAL lock_timeout TO '2s'")

    alter table(:devices) do
      remove_if_exists(:client_token_id, :binary_id)
      remove_if_exists(:gateway_token_id, :binary_id)
    end
  end

  def down, do: :ok
end
