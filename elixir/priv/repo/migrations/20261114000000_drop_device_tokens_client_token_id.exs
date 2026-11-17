defmodule Portal.Repo.Migrations.DropDeviceTokensClientTokenId do
  use Ecto.Migration

  # The column and its foreign key linked copies to client_tokens, which is
  # dropped next.
  def up do
    execute("SET LOCAL lock_timeout TO '2s'")

    alter table(:device_tokens) do
      remove_if_exists(:client_token_id)
    end
  end

  def down do
    raise Ecto.MigrationError,
          "device_tokens.client_token_id cannot be restored; client_tokens is dropped"
  end
end
