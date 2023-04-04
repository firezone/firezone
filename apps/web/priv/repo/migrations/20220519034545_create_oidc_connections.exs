defmodule Domain.Repo.Migrations.CreateOidcConnections do
  use Ecto.Migration

  def change do
    create table(:oidc_connections) do
      add(:provider, :string, null: false)
      add(:refresh_token, :string)
      add(:refreshed_at, :utc_datetime_usec)
      add(:refresh_response, :map)
      add(:user_id, references(:users, on_delete: :nothing), null: false)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:oidc_connections, [:user_id, :provider]))
  end
end
