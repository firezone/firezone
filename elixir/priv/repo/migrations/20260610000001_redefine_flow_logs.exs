defmodule Portal.Repo.Migrations.RedefineFlowLogs do
  use Ecto.Migration

  # Replaces the opaque `payload` jsonb with typed columns mirroring the
  # gateway's flow accounting (CompletedTcpFlow / CompletedUdpFlow in
  # rust/libs/connlib/tunnel/src/gateway/flow_tracker.rs) and adds the
  # event_id used by the /logs API. Each record captures one side of a flow:
  # device_id is the reporting device and role says which side it was.
  # flow_id is dropped: a flow side is identified by device_id, role,
  # protocol, and the tunnel 4-tuple within its time window, enforced by the
  # exclusion constraint below, and rows are addressed by event_id.
  # flow_logs is empty in every environment (ingestion has not launched), so
  # NOT NULL columns and indexes can be added directly without backfill or
  # concurrent builds.
  def change do
    execute(
      "ALTER TABLE flow_logs DROP CONSTRAINT flow_logs_pkey",
      "ALTER TABLE flow_logs ADD PRIMARY KEY (account_id, flow_id, device_id)"
    )

    alter table(:flow_logs) do
      remove(:payload, :map, null: false, default: %{})
      remove(:flow_id, :binary_id, null: false)

      add(:event_id, :bytea, null: false)

      add(:protocol, :string, null: false)
      add(:last_packet, :timestamptz, null: false)

      # No FK constraints on any of the ids below: flow history must survive
      # deletion of the referenced device, actor, auth provider, or resource.
      add(:auth_provider_id, :binary_id)
      add(:actor_id, :binary_id)
      add(:actor_name, :string)
      add(:actor_email, :string)

      add(:resource_id, :binary_id, null: false)
      add(:resource_name, :string, null: false)
      add(:resource_address, :string, null: false)

      add(:inner_src_ip, :inet, null: false)
      add(:inner_dst_ip, :inet, null: false)
      add(:inner_src_port, :integer, null: false)
      add(:inner_dst_port, :integer, null: false)
      add(:inner_domain, :string)

      add(:outer_src_ip, :inet, null: false)
      add(:outer_dst_ip, :inet, null: false)
      add(:outer_src_port, :integer, null: false)
      add(:outer_dst_port, :integer, null: false)

      add(:rx_packets, :bigint, null: false)
      add(:tx_packets, :bigint, null: false)
      add(:rx_bytes, :bigint, null: false)
      add(:tx_bytes, :bigint, null: false)
    end

    execute(
      "ALTER TABLE flow_logs ADD PRIMARY KEY (account_id, event_id)",
      "ALTER TABLE flow_logs DROP CONSTRAINT flow_logs_pkey"
    )

    create(
      constraint(:flow_logs, :flow_logs_event_id_must_be_12_bytes,
        check: "octet_length(event_id) = 12"
      )
    )

    create(constraint(:flow_logs, :flow_logs_protocol_chk, check: "protocol IN ('tcp', 'udp')"))

    execute(
      "CREATE EXTENSION IF NOT EXISTS btree_gist",
      "DROP EXTENSION IF EXISTS btree_gist"
    )

    # A flow side is unique within its time window. The range is half-open
    # so a flow split at time T ([start, T) then [T, end)) does not conflict
    # with itself, while duplicate or overlapping reports of the same flow
    # are deduplicated by ON CONFLICT DO NOTHING at ingestion. role is part
    # of the tuple so both sides of a flow can be recorded; Gateways always
    # report responder, enforced from the token type at ingestion.
    #
    # The GiST index backing this constraint is what makes the overlap check
    # efficient; together with the primary key it covers our access paths, so
    # the old (account_id, flow_start/flow_end) btrees are dropped below.
    create(
      constraint(:flow_logs, :flow_logs_unique_flow_per_window,
        exclude: """
        gist (
          account_id WITH =,
          device_id WITH =,
          role WITH =,
          protocol WITH =,
          inner_src_ip WITH =,
          inner_src_port WITH =,
          inner_dst_ip WITH =,
          inner_dst_port WITH =,
          tstzrange(flow_start, flow_end, '[)') WITH &&
        )
        """
      )
    )

    drop(index(:flow_logs, [:account_id, :flow_start]))
    drop(index(:flow_logs, [:account_id, :flow_end]))
  end
end
