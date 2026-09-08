defmodule Portal.Repo.Migrations.IndexGroupsNestedGroupIdpIds do
  use Ecto.Migration

  @disable_ddl_transaction true

  def up do
    create_if_not_exists(
      index(:groups, [:nested_group_idp_ids],
        using: :gin,
        name: :groups_nested_group_idp_ids_index,
        concurrently: true
      )
    )
  end

  def down do
    drop_if_exists(
      index(:groups, [:nested_group_idp_ids],
        name: :groups_nested_group_idp_ids_index,
        concurrently: true
      )
    )
  end
end
