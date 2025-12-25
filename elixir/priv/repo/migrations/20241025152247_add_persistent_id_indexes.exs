defmodule Portal.Repo.Migrations.AddPersistentIdIndexes do
  use Ecto.Migration

  def change do
    execute("""
          CREATE INDEX resource_persistent_id_index
          ON resources (persistent_id)
          WHERE replaced_by_resource_id IS NULL
    """)

    execute("""
          CREATE INDEX policy_persistent_id_index
          ON policies (persistent_id)
          WHERE replaced_by_policy_id IS NULL
    """)
  end
end
