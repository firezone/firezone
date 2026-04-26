defmodule Portal.Repo.Migrations.CascadeParentDeleteToDevices do
  use Ecto.Migration

  def up do
    execute("ALTER TABLE devices DROP CONSTRAINT devices_actor_id_fkey")

    execute("""
    ALTER TABLE devices
    ADD CONSTRAINT devices_actor_id_fkey
    FOREIGN KEY (account_id, actor_id)
    REFERENCES actors(account_id, id)
    ON DELETE CASCADE
    """)

    execute("ALTER TABLE devices DROP CONSTRAINT devices_site_id_fkey")

    execute("""
    ALTER TABLE devices
    ADD CONSTRAINT devices_site_id_fkey
    FOREIGN KEY (account_id, site_id)
    REFERENCES sites(account_id, id)
    ON DELETE CASCADE
    """)
  end

  def down do
    execute("ALTER TABLE devices DROP CONSTRAINT devices_actor_id_fkey")

    execute("""
    ALTER TABLE devices
    ADD CONSTRAINT devices_actor_id_fkey
    FOREIGN KEY (account_id, actor_id)
    REFERENCES actors(account_id, id)
    """)

    execute("ALTER TABLE devices DROP CONSTRAINT devices_site_id_fkey")

    execute("""
    ALTER TABLE devices
    ADD CONSTRAINT devices_site_id_fkey
    FOREIGN KEY (account_id, site_id)
    REFERENCES sites(account_id, id)
    """)
  end
end
