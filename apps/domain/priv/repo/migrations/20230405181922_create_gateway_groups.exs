defmodule Domain.Repo.Migrations.CreateGatewayGroups do
  use Ecto.Migration

  def change do
    create table(:gateway_groups, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(:name_prefix, :string, null: false)

      add(:tags, {:array, :string}, null: false, default: [])

      add(:deleted_at, :utc_datetime_usec)
      timestamps(type: :utc_datetime_usec)
    end

    # Used to match by tags
    # XXX: Should be per account in future.
    execute("CREATE INDEX gateway_group_tags_idx on gateway_groups USING GIN (tags)")

    # Used to enforce unique names
    # XXX: Should be per account in future.
    create(index(:gateway_groups, [:name_prefix], unique: true, where: "deleted_at IS NULL"))
  end
end
