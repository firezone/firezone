defmodule Domain.Repo.Migrations.CreateRelayGroups do
  use Ecto.Migration

  def change do
    create table(:relay_groups, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(:name, :string, null: false)

      add(:deleted_at, :utc_datetime_usec)
      timestamps(type: :utc_datetime_usec)
    end

    # Used to enforce unique names
    # XXX: Should be per account in future.
    create(index(:relay_groups, [:name], unique: true, where: "deleted_at IS NULL"))
  end
end
