defmodule Portal.Repo.Migrations.CreateRelayGroups do
  use Ecto.Migration

  def change do
    create table(:relay_groups, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(:name, :string, null: false)

      add(:account_id, references(:accounts, type: :binary_id))

      add(:deleted_at, :utc_datetime_usec)
      timestamps(type: :utc_datetime_usec)
    end

    # Used to enforce unique names
    create(index(:relay_groups, [:account_id, :name], unique: true, where: "deleted_at IS NULL"))

    create(
      index(:relay_groups, [:name],
        unique: true,
        where: "deleted_at IS NULL AND account_id IS NULL"
      )
    )
  end
end
