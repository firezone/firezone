defmodule FzHttp.Repo.Migrations.RenameDevicesToTunnels do
  use Ecto.Migration

  def change do
    rename table(:devices), to: table(:tunnels)
    execute "ALTER INDEX devices_pkey RENAME TO tunnels_pkey"
    execute "ALTER INDEX devices_ipv4_index RENAME TO tunnels_ipv4_index"
    execute "ALTER INDEX devices_ipv6_index RENAME TO tunnels_ipv6_index"
    execute "ALTER INDEX devices_public_key_index RENAME TO tunnels_public_key_index"
    execute "ALTER INDEX devices_user_id_index RENAME TO tunnels_user_id_index"
    execute "ALTER INDEX devices_user_id_name_index RENAME TO tunnels_user_id_name_index"
    execute "ALTER INDEX devices_uuid_index RENAME TO tunnels_uuid_index"
    execute "ALTER TABLE tunnels RENAME CONSTRAINT devices_user_id_fkey TO tunnels_user_id_fkey"
    execute "ALTER SEQUENCE devices_id_seq RENAME TO tunnels_id_seq"
  end
end
