defmodule Portal.Repo.Migrations.MoveFlowLogsPkeyToLogId do
  @moduledoc """
  Moves the flow_logs primary key to (account_id, log_id, flow_start) so the
  table is keyed by its public handle like the other log tables; flow_start
  rides along only because Postgres requires the partition key in every
  primary key on a partitioned table.

  The natural flow identity that was the primary key becomes a unique
  constraint. Its column order is preserved: its (account_id, flow_start)
  prefix serves account-scoped time-range listing, and it remains the
  open/close upsert conflict target. The standalone log_id index is dropped;
  point lookups are account-scoped and now use the primary key prefix.

  Runs in one transaction, so the upsert never observes a state without its
  arbiter index. Index builds take ACCESS EXCLUSIVE on the partitions.
  """
  use Ecto.Migration

  @identity_columns "account_id, flow_start, device_id, resource_id, " <>
                      "inner_dst_ip, inner_dst_port, role, protocol, inner_src_ip, inner_src_port"

  def up do
    execute(
      "ALTER TABLE flow_logs ADD CONSTRAINT flow_logs_identity_key UNIQUE (#{@identity_columns})"
    )

    execute("ALTER TABLE flow_logs DROP CONSTRAINT flow_logs_pkey")

    execute(
      "ALTER TABLE flow_logs ADD CONSTRAINT flow_logs_pkey " <>
        "PRIMARY KEY (account_id, log_id, flow_start)"
    )

    execute("DROP INDEX IF EXISTS flow_logs_log_id_index")
  end

  def down do
    execute("CREATE INDEX IF NOT EXISTS flow_logs_log_id_index ON flow_logs (log_id)")
    execute("ALTER TABLE flow_logs DROP CONSTRAINT flow_logs_pkey")

    execute(
      "ALTER TABLE flow_logs ADD CONSTRAINT flow_logs_pkey PRIMARY KEY (#{@identity_columns})"
    )

    execute("ALTER TABLE flow_logs DROP CONSTRAINT flow_logs_identity_key")
  end
end
