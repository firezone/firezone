defmodule Portal.Repo.Migrations.ScopeGatewayGroupsNameIndexByManagedBy do
  use Ecto.Migration

  # With the introduction of Internet Sites, some customers may have already named
  # one of their Sites "Internet". This migration will scope the name constraint to
  # include the managed_by column.
  def change do
    execute("DROP INDEX gateway_groups_account_id_name_index")

    create(
      index(:gateway_groups, [:account_id, :name, :managed_by],
        name: :gateway_groups_account_id_name_managed_by_index,
        unique: true,
        where: "deleted_at IS NULL"
      )
    )
  end
end
