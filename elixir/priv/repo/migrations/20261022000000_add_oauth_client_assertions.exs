defmodule Portal.Repo.Migrations.AddOAuthClientAssertions do
  use Ecto.Migration

  def change do
    alter table(:oauth_clients) do
      add(:token_endpoint_auth_method, :text, null: false, default: "none")
      add(:jwks_uri, :text)
    end

    create table(:oauth_client_assertions, primary_key: false) do
      add(:id, :binary, primary_key: true)
      add(:expires_at, :timestamptz, null: false)
    end

    create(index(:oauth_client_assertions, [:expires_at]))
  end
end
