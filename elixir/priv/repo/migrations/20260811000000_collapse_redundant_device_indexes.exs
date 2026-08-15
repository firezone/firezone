defmodule Portal.Repo.Migrations.CollapseRedundantDeviceIndexes do
  @moduledoc """
  Folds five `devices` indexes into two.

  Four of the fourteen indexes on `devices` only existed because a wider index
  that already covered their columns was predicated on something the query
  could not be proven to satisfy:

    * `(account_id, actor_id)` and `(account_id, site_id)` duplicate the leading
      columns of the two firezone_id unique indexes. They survived because those
      indexes were predicated on `type`, while the `ON DELETE CASCADE` from
      `actors` and `sites` emits `WHERE $1 = account_id AND $2 = actor_id` with
      no `type` qual, which Postgres cannot match against a `type` predicate.
      The check constraints make `actor_id IS NOT NULL` equivalent to
      `type = 'client'` (and site to gateway), so repredicating on the column
      covers the same rows and admits the cascade, since `actor_id = $2` proves
      `actor_id IS NOT NULL`.

    * `(account_id, id, type)` exists only as the target of the
      `static_device_pool_members` foreign key, and `(account_id, type)` only to
      list an account's devices of one type. A foreign key matches a unique
      index by column set rather than column order, so reordering to
      `(account_id, type, id)` keeps the key valid and leaves `(account_id,
      type)` as a usable prefix. Point lookups keep using the primary key.

    * `(account_id, actor_id, last_attested_cert_fingerprint)` is replaced by
      `(account_id, last_attested_cert_issuer, last_attested_cert_serial,
      actor_id)`. Issuer and serial together identify a certificate (RFC 5280
      4.1.2.2), so the per-actor uniqueness is unchanged, and the leading
      `(account_id, issuer, serial)` is the shape a revocation list is matched
      by. Its name also fits in 63 characters, where the fingerprint index name
      was truncated and so never matched the `unique_constraint/3` naming it.

  Every build and drop is concurrent, so writes to `devices` (client connects)
  are never blocked. The foreign key is rebuilt `NOT VALID` and validated
  separately to keep its lock on `devices` catalog-only; for the seconds between
  the drop and the re-add, a pool member could reference a gateway.
  """
  use Ecto.Migration

  @disable_ddl_transaction true

  def up do
    create_if_not_exists(
      unique_index(:devices, [:account_id, :actor_id, :firezone_id],
        where: "actor_id IS NOT NULL",
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

    drop_if_exists(
      index(:devices, [:account_id, :actor_id],
        name: :devices_account_id_actor_id_index,
        concurrently: true
      )
    )

    create_if_not_exists(
      unique_index(:devices, [:account_id, :site_id, :firezone_id],
        where: "site_id IS NOT NULL",
        name: :devices_account_id_site_id_firezone_id_tmp_index,
        concurrently: true
      )
    )

    drop_if_exists(
      index(:devices, [:account_id, :site_id, :firezone_id],
        name: :devices_account_id_site_id_firezone_id_index,
        concurrently: true
      )
    )

    execute("""
    ALTER INDEX devices_account_id_site_id_firezone_id_tmp_index
    RENAME TO devices_account_id_site_id_firezone_id_index
    """)

    drop_if_exists(
      index(:devices, [:account_id, :site_id],
        name: :devices_account_id_site_id_index,
        concurrently: true
      )
    )

    create_if_not_exists(
      unique_index(:devices, [:account_id, :type, :id],
        name: :devices_account_id_type_id_index,
        concurrently: true
      )
    )

    execute("""
    ALTER TABLE static_device_pool_members
    DROP CONSTRAINT IF EXISTS static_device_pool_members_device_id_device_type_fkey
    """)

    drop_if_exists(
      index(:devices, [:account_id, :id, :type],
        name: :devices_account_id_id_type_index,
        concurrently: true
      )
    )

    execute("""
    ALTER TABLE static_device_pool_members
    ADD CONSTRAINT static_device_pool_members_device_id_device_type_fkey
    FOREIGN KEY (account_id, device_id, device_type)
    REFERENCES devices(account_id, id, type)
    ON DELETE CASCADE
    NOT VALID
    """)

    execute("""
    ALTER TABLE static_device_pool_members
    VALIDATE CONSTRAINT static_device_pool_members_device_id_device_type_fkey
    """)

    drop_if_exists(
      index(:devices, [:account_id, :type],
        name: :devices_account_id_type_index,
        concurrently: true
      )
    )

    create_if_not_exists(
      unique_index(
        :devices,
        [:account_id, :last_attested_cert_issuer, :last_attested_cert_serial, :actor_id],
        where: "last_attested_cert_issuer IS NOT NULL AND last_attested_cert_serial IS NOT NULL",
        name: :devices_account_id_cert_issuer_serial_actor_id_index,
        concurrently: true
      )
    )

    drop_if_exists(
      index(:devices, [:account_id, :actor_id, :last_attested_cert_fingerprint],
        name: :devices_account_id_actor_id_last_attested_cert_fingerprint_inde,
        concurrently: true
      )
    )
  end

  def down do
    create_if_not_exists(
      unique_index(:devices, [:account_id, :actor_id, :last_attested_cert_fingerprint],
        where: "last_attested_cert_fingerprint IS NOT NULL",
        name: :devices_account_id_actor_id_last_attested_cert_fingerprint_inde,
        concurrently: true
      )
    )

    drop_if_exists(
      index(:devices, [:account_id, :last_attested_cert_issuer, :last_attested_cert_serial],
        name: :devices_account_id_cert_issuer_serial_actor_id_index,
        concurrently: true
      )
    )

    create_if_not_exists(
      index(:devices, [:account_id, :type],
        name: :devices_account_id_type_index,
        concurrently: true
      )
    )

    create_if_not_exists(
      unique_index(:devices, [:account_id, :id, :type],
        name: :devices_account_id_id_type_index,
        concurrently: true
      )
    )

    execute("""
    ALTER TABLE static_device_pool_members
    DROP CONSTRAINT IF EXISTS static_device_pool_members_device_id_device_type_fkey
    """)

    drop_if_exists(
      index(:devices, [:account_id, :type, :id],
        name: :devices_account_id_type_id_index,
        concurrently: true
      )
    )

    execute("""
    ALTER TABLE static_device_pool_members
    ADD CONSTRAINT static_device_pool_members_device_id_device_type_fkey
    FOREIGN KEY (account_id, device_id, device_type)
    REFERENCES devices(account_id, id, type)
    ON DELETE CASCADE
    NOT VALID
    """)

    execute("""
    ALTER TABLE static_device_pool_members
    VALIDATE CONSTRAINT static_device_pool_members_device_id_device_type_fkey
    """)

    create_if_not_exists(
      index(:devices, [:account_id, :site_id],
        where: "site_id IS NOT NULL",
        name: :devices_account_id_site_id_index,
        concurrently: true
      )
    )

    create_if_not_exists(
      unique_index(:devices, [:account_id, :site_id, :firezone_id],
        where: "type = 'gateway'",
        name: :devices_account_id_site_id_firezone_id_tmp_index,
        concurrently: true
      )
    )

    drop_if_exists(
      index(:devices, [:account_id, :site_id, :firezone_id],
        name: :devices_account_id_site_id_firezone_id_index,
        concurrently: true
      )
    )

    execute("""
    ALTER INDEX devices_account_id_site_id_firezone_id_tmp_index
    RENAME TO devices_account_id_site_id_firezone_id_index
    """)

    create_if_not_exists(
      index(:devices, [:account_id, :actor_id],
        where: "actor_id IS NOT NULL",
        name: :devices_account_id_actor_id_index,
        concurrently: true
      )
    )

    create_if_not_exists(
      unique_index(:devices, [:account_id, :actor_id, :firezone_id],
        where: "type = 'client'",
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
