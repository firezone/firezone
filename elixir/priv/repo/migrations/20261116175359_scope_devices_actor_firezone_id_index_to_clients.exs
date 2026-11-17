defmodule Portal.Repo.Migrations.ScopeDevicesActorFirezoneIdIndexToClients do
  use Ecto.Migration

  @disable_ddl_transaction true

  def up do
    swap_index("type = 'client'")
  end

  def down do
    swap_index("actor_id IS NOT NULL")
  end

  defp swap_index(where) do
    create_if_not_exists(
      unique_index(:devices, [:account_id, :actor_id, :firezone_id],
        where: where,
        name: :devices_account_id_actor_id_firezone_id_tmp_index,
        concurrently: true
      )
    )

    drop_if_exists(
      index(:devices, [:account_id, :actor_id, :firezone_id],
        name: :devices_account_id_actor_id_firezone_id_index,
        concurrently: true
      )
    )

    execute("""
    ALTER INDEX devices_account_id_actor_id_firezone_id_tmp_index
    RENAME TO devices_account_id_actor_id_firezone_id_index
    """)
  end
end
