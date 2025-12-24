defmodule Portal.Repo.Migrations.CreateAuthIdentities do
  use Ecto.Migration

  def change do
    create table(:auth_identities, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(:actor_id, references(:actors, type: :binary_id), null: false)

      add(:provider_id, references(:auth_providers, type: :binary_id), null: false)
      add(:provider_identifier, :string, null: false)
      add(:provider_state, :map, null: false, default: %{})

      add(:last_seen_user_agent, :string)
      add(:last_seen_remote_ip, :inet)
      add(:last_seen_at, :utc_datetime_usec)

      add(:account_id, references(:accounts, type: :binary_id), null: false)

      add(:deleted_at, :utc_datetime_usec)
    end

    create(
      index(:auth_identities, [:account_id, :provider_id, :provider_identifier],
        name: :auth_identities_account_id_provider_id_provider_identifier_idx,
        where: "deleted_at IS NULL",
        unique: true
      )
    )
  end
end
