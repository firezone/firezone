defmodule Domain.Repo.Migrations.AddTokens do
  use Ecto.Migration

  def change do
    create table(:tokens, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(:context, :string, null: false)
      add(:secret_salt, :string, null: false)
      add(:secret_hash, :string, null: false)

      add(:user_agent, :string, null: false)
      add(:remote_ip, :inet, null: false)

      add(:created_by, :string, null: false)
      add(:created_by_identity_id, references(:auth_identities, type: :binary_id))

      add(:account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:expires_at, :utc_datetime_usec, null: false)
      add(:deleted_at, :utc_datetime_usec)
      timestamps()
    end

    create(index(:tokens, [:account_id, :context], where: "deleted_at IS NULL"))
  end
end
