defmodule Portal.Repo.Migrations.AddWebhookSecretToOktaDirectories do
  use Ecto.Migration

  def change do
    alter table(:okta_directories) do
      add(:webhook_secret, :string,
        null: false,
        default: fragment("encode(gen_random_bytes(32), 'hex')")
      )
    end
  end
end
