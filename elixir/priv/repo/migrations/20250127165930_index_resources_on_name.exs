defmodule Portal.Repo.Migrations.IndexResourcesOnName do
  use Ecto.Migration

  def change do
    create(
      index(
        :resources,
        [:account_id, :name],
        where: "deleted_at IS NULL"
      )
    )
  end
end
