defmodule Portal.Repo.Migrations.RecreateFlowsAgmIndex do
  use Ecto.Migration

  @disable_ddl_transaction true

  def change do
    create_if_not_exists(
      index(:flows, [:actor_group_membership_id],
        concurrently: true,
        name: :flows_actor_group_membership_id_idx
      )
    )
  end
end
