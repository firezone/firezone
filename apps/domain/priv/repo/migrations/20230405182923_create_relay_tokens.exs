defmodule Domain.Repo.Migrations.CreateRelayTokens do
  use Ecto.Migration

  def change do
    create table(:relay_tokens, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:hash, :string)

      add(:account_id, references(:accounts, type: :binary_id), null: false)
      add(:group_id, references(:relay_groups, type: :binary_id), null: false)

      add(:deleted_at, :utc_datetime_usec)
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(
      constraint(:relay_tokens, :hash_not_null,
        check: """
        (hash is NOT NULL AND deleted_at IS NULL)
        OR (hash is NULL AND deleted_at IS NOT NULL)
        """
      )
    )

    create(index(:relay_tokens, [:account_id], where: "deleted_at IS NULL"))
  end
end
