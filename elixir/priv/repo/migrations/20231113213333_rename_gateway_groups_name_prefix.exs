defmodule Portal.Repo.Migrations.RenameGatewayGroupsNamePrefix do
  use Ecto.Migration

  def change do
    rename(table(:gateway_groups), :name_prefix, to: :name)

    execute("""
    ALTER INDEX gateway_groups_account_id_name_prefix_index
    RENAME TO gateway_groups_account_id_name_index
    """)
  end
end
