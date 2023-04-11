defmodule Domain.Repo.Migrations.CreateGatewayTokens do
  use Ecto.Migration

  def change do
    create table(:gateway_tokens, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:hash, :string)

      add(:group_id, references(:gateway_groups, type: :binary_id), null: false)

      add(:deleted_at, :utc_datetime_usec)
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(
      constraint(:gateway_tokens, :hash_not_null,
        check: """
        (hash is NOT NULL AND deleted_at IS NULL)
        OR (hash is NULL AND deleted_at IS NOT NULL)
        """
      )
    )

    create(index(:gateway_tokens, [:id], unique: true, where: "deleted_at IS NULL"))
  end
end
