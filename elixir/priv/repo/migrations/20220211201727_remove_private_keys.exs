defmodule Portal.Repo.Migrations.RemovePrivateKeys do
  use Ecto.Migration

  def change do
    alter table(:devices) do
      remove(:private_key)
      remove(:server_public_key)
      remove(:config_token)
      remove(:config_token_expires_at)
    end
  end
end
