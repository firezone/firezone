defmodule Portal.Repo.Migrations.PartitionFlowLogs do
  use Ecto.Migration

  @moduledoc """
  Converts flow_logs into a table partitioned by RANGE (flow_start), one daily
  partition per UTC day, so old logs are reclaimed by dropping whole partitions
  (a metadata-only operation) instead of a scan-and-vacuum bulk DELETE.

  This is a manual migration: it is gated by `run_manual_migrations`.

  A plain table cannot be converted to a partitioned one in place, so the table
  is recreated. flow_logs is empty in every environment (ingestion has not
  launched), so there is no data to migrate. The columns, types, defaults, and
  NOT NULLs are copied from the existing table with `LIKE` so the shape stays
  byte-for-byte what reshape + the later column adds produced; only the
  partitioning, primary key, CHECK constraints, and the single event_id index are
  restated here (LIKE does not carry those over).

  The primary key becomes the natural flow identity (see the `up` body) rather
  than (account_id, event_id, flow_start): it enforces flow uniqueness directly
  and is the upsert conflict target, and event_id is demoted to a random public
  handle with a plain btree. The PK includes flow_start because Postgres requires
  the partition key in every UNIQUE and PRIMARY KEY constraint on a partitioned
  table; flow_start is immutable, so a row never needs to move between partitions.

  The accounts foreign key is not recreated: on a partitioned table it would force
  every partition create/drop to lock accounts to manage FK triggers, deadlocking
  with account deletion. account_id stays a plain column and
  Portal.Workers.DeleteAccount purges a deleted account's logs explicitly.

  Daily partitions are pre-created here from a fixed lower bound (covering the
  existing fixtures and any already-issued authorizations) through a forward
  buffer. `Portal.Workers.PartitionFlowLogs` maintains the window afterwards:
  pre-creating upcoming days and dropping expired ones.
  """

  def up do
    execute("ALTER TABLE flow_logs RENAME TO flow_logs_unpartitioned")

    execute("""
    CREATE TABLE flow_logs (LIKE flow_logs_unpartitioned INCLUDING DEFAULTS)
    PARTITION BY RANGE (flow_start)
    """)

    execute("DROP TABLE flow_logs_unpartitioned")

    # The primary key is the natural flow identity: the reporting side
    # (account_id, device_id, role), the inner tunnel 6-tuple, the resource, and
    # flow_start. It enforces flow uniqueness directly and is the open/close
    # upsert conflict target; event_id therefore needs no uniqueness of its own
    # and is just a random public handle. flow_start is in the key both because it is part of
    # the identity (connlib reuses a 6-tuple with a new start across a
    # split/reconnect) and because Postgres requires the partition key in every
    # primary key on a partitioned table.
    execute("""
    ALTER TABLE flow_logs
    ADD CONSTRAINT flow_logs_pkey PRIMARY KEY
      (account_id, flow_start, device_id, resource_id, inner_dst_ip, inner_dst_port,
       role, protocol, inner_src_ip, inner_src_port)
    """)

    # No foreign key to accounts. flow_logs already drops the policy / resource /
    # actor FKs (a log must survive deletion of what it references), and on a
    # partitioned table an FK forces every partition create/drop to lock the
    # referenced table to manage its FK triggers, which deadlocks with account
    # deletion. account_id is therefore a plain column; Portal.Workers.DeleteAccount
    # purges a deleted account's flow logs explicitly instead of via cascade.
    execute(
      "ALTER TABLE flow_logs ADD CONSTRAINT flow_logs_role_chk " <>
        "CHECK (role IN ('initiator', 'responder'))"
    )

    execute(
      "ALTER TABLE flow_logs ADD CONSTRAINT flow_logs_protocol_chk " <>
        "CHECK (protocol IN ('tcp', 'udp'))"
    )

    execute(
      "ALTER TABLE flow_logs ADD CONSTRAINT flow_logs_event_id_must_be_12_bytes " <>
        "CHECK (octet_length(event_id) = 12)"
    )

    execute(
      "ALTER TABLE flow_logs ADD CONSTRAINT flow_logs_ports_in_range " <>
        "CHECK (inner_src_port BETWEEN 0 AND 65535 AND inner_dst_port BETWEEN 0 AND 65535 AND " <>
        "outer_src_port BETWEEN 0 AND 65535 AND outer_dst_port BETWEEN 0 AND 65535)"
    )

    execute(
      "ALTER TABLE flow_logs ADD CONSTRAINT flow_logs_counters_non_negative " <>
        "CHECK (rx_packets >= 0 AND tx_packets >= 0 AND rx_bytes >= 0 AND tx_bytes >= 0)"
    )

    execute(
      "ALTER TABLE flow_logs ADD CONSTRAINT flow_logs_close_complete " <>
        "CHECK (flow_end IS NULL OR (last_packet IS NOT NULL AND rx_packets IS NOT NULL AND " <>
        "tx_packets IS NOT NULL AND rx_bytes IS NOT NULL AND tx_bytes IS NOT NULL))"
    )

    # event_id is the only secondary index: a plain btree for point lookups by
    # the public id. event_id is a 0xF-namespaced 92-bit random value
    # (Portal.Types.EventId.build_flow_log/0), set once on insert; it is not
    # unique-constrained (flow uniqueness is the identity primary key's job), and
    # a unique index could not live here anyway since a unique index on a
    # partitioned table must include the partition key. The (account_id,
    # flow_start) / (account_id, flow_end) secondaries from
    # 20260320_create_flow_logs are dropped; account-scoped time-range listing is
    # served by partition pruning plus the primary key's (account_id, flow_start)
    # prefix.
    execute("CREATE INDEX IF NOT EXISTS flow_logs_event_id_index ON flow_logs (event_id)")

    seed_partitions()
  end

  def down do
    execute("CREATE TABLE flow_logs_unpartitioned (LIKE flow_logs INCLUDING DEFAULTS)")
    execute("DROP TABLE flow_logs")
    execute("ALTER TABLE flow_logs_unpartitioned RENAME TO flow_logs")

    execute("""
    ALTER TABLE flow_logs
    ADD CONSTRAINT flow_logs_pkey PRIMARY KEY (account_id, event_id)
    """)

    execute("""
    ALTER TABLE flow_logs
    ADD CONSTRAINT flow_logs_account_id_fkey
    FOREIGN KEY (account_id) REFERENCES accounts(id) ON DELETE CASCADE
    """)

    execute(
      "ALTER TABLE flow_logs ADD CONSTRAINT flow_logs_role_chk " <>
        "CHECK (role IN ('initiator', 'responder'))"
    )

    execute(
      "ALTER TABLE flow_logs ADD CONSTRAINT flow_logs_protocol_chk " <>
        "CHECK (protocol IN ('tcp', 'udp'))"
    )

    execute(
      "ALTER TABLE flow_logs ADD CONSTRAINT flow_logs_event_id_must_be_12_bytes " <>
        "CHECK (octet_length(event_id) = 12)"
    )

    execute(
      "ALTER TABLE flow_logs ADD CONSTRAINT flow_logs_ports_in_range " <>
        "CHECK (inner_src_port BETWEEN 0 AND 65535 AND inner_dst_port BETWEEN 0 AND 65535 AND " <>
        "outer_src_port BETWEEN 0 AND 65535 AND outer_dst_port BETWEEN 0 AND 65535)"
    )

    execute(
      "ALTER TABLE flow_logs ADD CONSTRAINT flow_logs_counters_non_negative " <>
        "CHECK (rx_packets >= 0 AND tx_packets >= 0 AND rx_bytes >= 0 AND tx_bytes >= 0)"
    )

    execute(
      "ALTER TABLE flow_logs ADD CONSTRAINT flow_logs_close_complete " <>
        "CHECK (flow_end IS NULL OR (last_packet IS NOT NULL AND rx_packets IS NOT NULL AND " <>
        "tx_packets IS NOT NULL AND rx_bytes IS NOT NULL AND tx_bytes IS NOT NULL))"
    )

    execute(
      "CREATE INDEX IF NOT EXISTS flow_logs_account_id_flow_start_index " <>
        "ON flow_logs (account_id, flow_start)"
    )

    execute(
      "CREATE INDEX IF NOT EXISTS flow_logs_account_id_flow_end_index " <>
        "ON flow_logs (account_id, flow_end)"
    )

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS flow_logs_flow_identity ON flow_logs
    (account_id, flow_start, device_id, resource_id, inner_dst_ip, inner_dst_port,
     role, protocol, inner_src_ip, inner_src_port)
    """)
  end

  # Pre-create one partition per day from a fixed lower bound through a forward
  # buffer. The lower bound predates any issued authorization, so an early flow
  # always finds a partition; the worker prunes the front to the retention window
  # on its first run.
  defp seed_partitions do
    execute("""
    DO $$
    DECLARE
      d date;
    BEGIN
      FOR d IN SELECT generate_series('2026-03-01'::date, CURRENT_DATE + 14, '1 day')::date
      LOOP
        EXECUTE format(
          'CREATE TABLE IF NOT EXISTS flow_logs_%s PARTITION OF flow_logs ' ||
            'FOR VALUES FROM (%L) TO (%L)',
          to_char(d, 'YYYYMMDD'), d::timestamptz, (d + 1)::timestamptz
        );
      END LOOP;
    END $$;
    """)
  end
end
