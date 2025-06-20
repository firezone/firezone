defmodule Domain.Repo.Migrations.IndexActorsOnType do
  use Ecto.Migration

  @disable_ddl_transaction true

  def up do
    create(
      index(:actors, [:account_id, :type],
        name: :index_actors_on_account_id_and_type,
        where: "deleted_at IS NULL",
        concurrently: true
      )
    )
  end

  def down do
    drop(
      index(:actors, [:account_id, :type],
        name: :index_actors_on_account_id_and_type,
        concurrently: true
      )
    )
  end
end
