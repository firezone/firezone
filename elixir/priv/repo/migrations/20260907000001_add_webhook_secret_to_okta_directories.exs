defmodule Portal.Repo.Migrations.AddWebhookSecretToOktaDirectories do
  use Ecto.Migration

  def change do
    alter table(:okta_directories) do
      add(:webhook_secret, :string,
        null: false,
        default: fragment("replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '')")
      )
    end
  end
end
