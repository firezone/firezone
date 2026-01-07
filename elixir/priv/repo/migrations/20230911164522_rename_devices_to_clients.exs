defmodule Portal.Repo.Migrations.RenameDevicesToClients do
  use Ecto.Migration

  def change do
    rename(table(:configurations), :devices_upstream_dns, to: :clients_upstream_dns)

    execute("""
    ALTER INDEX devices_account_id_ipv4_index
    RENAME TO clients_account_id_ipv4_index
    """)

    execute("""
    ALTER INDEX devices_account_id_ipv6_index
    RENAME TO clients_account_id_ipv6_index
    """)

    execute("""
    ALTER INDEX devices_account_id_actor_id_external_id_index
    RENAME TO clients_account_id_actor_id_external_id_index
    """)

    execute("""
    ALTER INDEX devices_account_id_actor_id_name_index
    RENAME TO clients_account_id_actor_id_name_index
    """)

    execute("""
    ALTER INDEX devices_account_id_actor_id_public_key_index
    RENAME TO clients_account_id_actor_id_public_key_index
    """)

    rename(table(:devices), to: table(:clients))
  end
end
