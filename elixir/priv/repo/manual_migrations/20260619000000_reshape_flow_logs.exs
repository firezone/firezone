defmodule Portal.Repo.Migrations.ReshapeFlowLogs do
  use Ecto.Migration

  @moduledoc """
  Reshapes flow_logs for per-flow ingest tokens and incremental (open/close)
  reporting.

  This is a manual migration: it is gated by `run_manual_migrations` and is
  meant to be run by hand rather than automatically on deploy. It alters the
  table in place instead of dropping and recreating it, so the table, its FK
  to accounts, and any grants survive.

  The opaque `flow_id` + `payload` jsonb are replaced by:

  - `event_id`: the public row address, a 12-byte flow_log event_id (see
    `Portal.Types.EventId`), promoted into the primary key as
    `(account_id, event_id)` to match the other audit log streams.
  - typed attribution columns sourced from the verified ingest token
    (no FKs: a flow log must survive deletion of the policy, resource, or
    actor it references).
  - typed columns mirroring the gateway's flow accounting (CompletedTcpFlow /
    CompletedUdpFlow in rust/libs/connlib/tunnel/src/gateway/flow_tracker.rs):
    the inner tunnel 4-tuple + domain, the outer 4-tuple, last_packet, and the
    byte/packet counters. Nothing is left in an opaque blob.

  `flow_end` becomes nullable so a flow can be opened first and completed
  later. The temporal ordering CHECKs from the original table
  (`flow_end_after_start`, `flow_start_in_past`, `flow_end_in_past`) are dropped:
  flow timestamps come from endpoint clocks that may be skewed (or stepped by NTP
  mid-flow), and rejecting a skewed flow would lose an audit record we can never
  recover. Skew is surfaced downstream against the trusted `authorized_at` /
  `inserted_at` pair instead.

  flow_logs is empty in every environment (ingestion has not launched), so the
  NOT NULL columns and the new primary key are added directly without backfill.
  """

  def up do
    execute("ALTER TABLE flow_logs DROP CONSTRAINT flow_logs_pkey")

    alter table(:flow_logs) do
      remove(:flow_id)
      remove(:payload)

      add(:event_id, :bytea, null: false)

      # Attribution snapshot, copied from the verified ingest token. No FKs so
      # the log survives deletion of the policy / provider / resource / actor it
      # references. The token always carries these, so they are NOT NULL, except:
      # actor_email (service accounts have none), auth_provider_id (not every
      # credential has one), and resource_address (internet and device-pool
      # resources have no address).
      add(:policy_id, :binary_id, null: false)
      add(:auth_provider_id, :binary_id)
      add(:resource_id, :binary_id, null: false)
      add(:resource_name, :string, null: false)
      add(:resource_address, :string)
      add(:actor_id, :binary_id, null: false)
      add(:actor_email, :string)
      add(:actor_name, :string, null: false)

      # When the portal authorized this flow (stamped into the ingest token). A
      # trusted, portal-stamped reference: comparing it and inserted_at against
      # the device-reported flow_start is how clock skew is detected downstream.
      add(:authorized_at, :timestamptz, null: false)

      # Connecting client's device / user-agent telemetry, as the gateway flow
      # tracker observes it (ClientProperties in flow_tracker.rs). All nullable:
      # availability is platform-dependent (e.g. identifier_for_vendor is iOS,
      # firebase_installation_id is Android).
      add(:client_version, :string)
      add(:device_os_name, :string)
      add(:device_os_version, :string)
      add(:device_serial, :string)
      add(:device_uuid, :string)
      add(:device_identifier_for_vendor, :string)
      add(:device_firebase_installation_id, :string)

      add(:protocol, :string, null: false)

      # Inner (decrypted) tunnel tuple: the flow's identity, known when the flow
      # opens. domain is nullable since only DNS resources carry one.
      add(:inner_src_ip, :inet, null: false)
      add(:inner_dst_ip, :inet, null: false)
      add(:inner_src_port, :integer, null: false)
      add(:inner_dst_port, :integer, null: false)
      add(:domain, :string)

      # Outer (WireGuard) tuple, known when the flow opens, so NOT NULL.
      add(:outer_src_ip, :inet, null: false)
      add(:outer_dst_ip, :inet, null: false)
      add(:outer_src_port, :integer, null: false)
      add(:outer_dst_port, :integer, null: false)

      # Accounting, filled in when the flow closes, so nullable to support
      # open-then-close reporting.
      add(:last_packet, :timestamptz)
      add(:rx_packets, :bigint)
      add(:tx_packets, :bigint)
      add(:rx_bytes, :bigint)
      add(:tx_bytes, :bigint)
    end

    execute("ALTER TABLE flow_logs ALTER COLUMN flow_end DROP NOT NULL")

    execute("ALTER TABLE flow_logs ADD PRIMARY KEY (account_id, event_id)")

    create(
      constraint(:flow_logs, :flow_logs_event_id_must_be_12_bytes,
        check: "octet_length(event_id) = 12"
      )
    )

    create(constraint(:flow_logs, :flow_logs_protocol_chk, check: "protocol IN ('tcp', 'udp')"))

    # Flow ordering is intentionally not enforced at rest. Flow timestamps come
    # from endpoint clocks that may be skewed (or stepped by NTP mid-flow), so a
    # skewed flow_start/flow_end is accepted rather than rejected (which would
    # lose an audit record); skew is surfaced downstream against authorized_at /
    # inserted_at. Drop the temporal CHECKs from 20260320_create_flow_logs.
    drop(constraint(:flow_logs, :flow_end_after_start))
    drop(constraint(:flow_logs, :flow_start_in_past))
    drop(constraint(:flow_logs, :flow_end_in_past))

    # Tunnel and WireGuard ports are 16-bit. The columns are plain integers, so
    # the range is enforced here rather than by the type.
    create(
      constraint(:flow_logs, :flow_logs_ports_in_range,
        check:
          "inner_src_port BETWEEN 0 AND 65535 AND inner_dst_port BETWEEN 0 AND 65535 AND " <>
            "outer_src_port BETWEEN 0 AND 65535 AND outer_dst_port BETWEEN 0 AND 65535"
      )
    )

    # Byte/packet counters are monotonic totals; negative values are nonsensical.
    # They are nullable (filled in on close), and NULL satisfies the CHECK.
    create(
      constraint(:flow_logs, :flow_logs_counters_non_negative,
        check: "rx_packets >= 0 AND tx_packets >= 0 AND rx_bytes >= 0 AND tx_bytes >= 0"
      )
    )

    # A closed flow must carry its accounting. The gateway flow tracker always
    # emits last_packet and all four counters on a completed flow (CompletedTcpFlow
    # / CompletedUdpFlow in flow_tracker.rs copy them unconditionally), so a close
    # missing them is a malformed report, not a clock-skew artifact. An open
    # (flow_end NULL) leaves them NULL and satisfies the CHECK. Individual counters
    # may legitimately be zero (one-way flows, payload-less SYN/ACK packets), so
    # only presence is enforced here, not a positive total.
    create(
      constraint(:flow_logs, :flow_logs_close_complete,
        check:
          "flow_end IS NULL OR (last_packet IS NOT NULL AND rx_packets IS NOT NULL AND " <>
            "tx_packets IS NOT NULL AND rx_bytes IS NOT NULL AND tx_bytes IS NOT NULL)"
      )
    )

    # A flow's identity is the reporting side (account, device, role), its
    # 6-tuple (protocol, the inner tunnel 4-tuple, resource), and when it
    # started. flow_start is part of the key because connlib reuses a 6-tuple
    # with a new start when a flow splits or reconnects (so two flows can share
    # a 6-tuple at different times), while two parallel flows can share a start
    # with different 6-tuples. The open and close reports of one flow carry the
    # same identity, so this index is also the upsert target.
    create(
      unique_index(
        :flow_logs,
        [
          :account_id,
          :flow_start,
          :device_id,
          :resource_id,
          :inner_dst_ip,
          :inner_dst_port,
          :role,
          :protocol,
          :inner_src_ip,
          :inner_src_port,
        ],
        name: :flow_logs_flow_identity
      )
    )
  end

  def down do
    drop(
      index(
        :flow_logs,
        [
          :account_id,
          :flow_start,
          :device_id,
          :resource_id,
          :inner_dst_ip,
          :inner_dst_port,
          :role,
          :protocol,
          :inner_src_ip,
          :inner_src_port,
        ],
        name: :flow_logs_flow_identity
      )
    )

    drop(constraint(:flow_logs, :flow_logs_close_complete))
    drop(constraint(:flow_logs, :flow_logs_counters_non_negative))
    drop(constraint(:flow_logs, :flow_logs_ports_in_range))
    drop(constraint(:flow_logs, :flow_logs_protocol_chk))
    drop(constraint(:flow_logs, :flow_logs_event_id_must_be_12_bytes))

    # Restore the temporal CHECKs dropped in `up`.
    create(constraint(:flow_logs, :flow_end_after_start, check: "flow_end >= flow_start"))
    create(constraint(:flow_logs, :flow_start_in_past, check: "flow_start <= now()"))
    create(constraint(:flow_logs, :flow_end_in_past, check: "flow_end <= now()"))

    execute("ALTER TABLE flow_logs DROP CONSTRAINT flow_logs_pkey")

    execute("ALTER TABLE flow_logs ALTER COLUMN flow_end SET NOT NULL")

    alter table(:flow_logs) do
      remove(:tx_bytes)
      remove(:rx_bytes)
      remove(:tx_packets)
      remove(:rx_packets)
      remove(:last_packet)
      remove(:outer_dst_port)
      remove(:outer_src_port)
      remove(:outer_dst_ip)
      remove(:outer_src_ip)
      remove(:domain)
      remove(:inner_dst_port)
      remove(:inner_src_port)
      remove(:inner_dst_ip)
      remove(:inner_src_ip)
      remove(:protocol)

      remove(:device_firebase_installation_id)
      remove(:device_identifier_for_vendor)
      remove(:device_uuid)
      remove(:device_serial)
      remove(:device_os_version)
      remove(:device_os_name)
      remove(:client_version)

      remove(:authorized_at)
      remove(:actor_name)
      remove(:actor_email)
      remove(:actor_id)
      remove(:resource_address)
      remove(:resource_name)
      remove(:resource_id)
      remove(:auth_provider_id)
      remove(:policy_id)

      remove(:event_id)

      add(:flow_id, :binary_id, null: false)
      add(:payload, :map, null: false, default: %{})
    end

    execute("ALTER TABLE flow_logs ADD PRIMARY KEY (account_id, flow_id, device_id)")
  end
end
