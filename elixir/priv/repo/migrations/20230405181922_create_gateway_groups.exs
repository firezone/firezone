defmodule Portal.Repo.Migrations.CreateGatewayGroups do
  use Ecto.Migration

  def change do
    create table(:gateway_groups, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(:name_prefix, :string, null: false)

      add(:tags, {:array, :string}, null: false, default: [])

      add(:account_id, references(:accounts, type: :binary_id), null: false)

      add(:deleted_at, :utc_datetime_usec)
      timestamps(type: :utc_datetime_usec)
    end

    # Used to match by tags
    execute("CREATE INDEX gateway_group_tags_idx on gateway_groups USING GIN (tags)")

    # Used to enforce unique names
    create(
      index(:gateway_groups, [:account_id, :name_prefix],
        unique: true,
        where: "deleted_at IS NULL"
      )
    )
  end
end
