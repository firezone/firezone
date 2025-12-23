defmodule Domain.Repo.Migrations.IndexGroupsOnNameAndType do
  use Ecto.Migration

  @disable_ddl_transaction true

  def change do
    create_if_not_exists(
      index(:groups, [:account_id, :name, :type],
        name: :index_groups_on_account_id_name_type,
        concurrently: true
      )
    )
  end
end
