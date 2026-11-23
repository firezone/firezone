defmodule Portal.Repo.Migrations.AddGroupsResourceIdIndex do
  @moduledoc """
  One direct-access group per resource, and the index the cascading delete
  from resources uses.
  """
  use Ecto.Migration

  @disable_ddl_transaction true

  def change do
    create_if_not_exists(
      unique_index(:groups, [:account_id, :resource_id],
        where: "resource_id IS NOT NULL",
        concurrently: true
      )
    )
  end
end
