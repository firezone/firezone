defmodule Portal.Repo.Migrations.RemoveReplacedByFromResources do
  use Ecto.Migration

  def change do
    alter table(:resources) do
      remove(
        :replaced_by_resource_id,
        references(:resources, type: :binary_id, on_delete: :nilify_all)
      )
    end
  end
end
