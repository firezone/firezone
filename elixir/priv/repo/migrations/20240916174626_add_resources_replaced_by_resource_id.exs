defmodule Portal.Repo.Migrations.AddResourcesReplacedByResourceId do
  use Ecto.Migration

  def change do
    alter table(:resources) do
      add(:persistent_id, :binary_id)

      add(
        :replaced_by_resource_id,
        references(:resources, type: :binary_id, on_delete: :delete_all)
      )
    end

    execute("UPDATE resources SET persistent_id = gen_random_uuid()")

    execute("ALTER TABLE resources ALTER COLUMN persistent_id SET NOT NULL")

    create(
      constraint(:resources, :replaced_resources_are_deleted,
        check: "replaced_by_resource_id IS NULL OR deleted_at IS NOT NULL"
      )
    )
  end
end
