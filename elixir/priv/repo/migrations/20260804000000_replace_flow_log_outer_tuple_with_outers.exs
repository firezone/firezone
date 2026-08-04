defmodule Portal.Repo.Migrations.ReplaceFlowLogOuterTupleWithOuters do
  use Ecto.Migration

  @moduledoc """
  Replaces the single outer WireGuard tuple with an ordered array of tuples.

  `flow_logs` is partitioned by `flow_start`. Adding and dropping columns on
  the partitioned parent recurses to every attached partition, and updating
  through the parent backfills rows in all of them. Existing scalar tuples are
  retained as one-element arrays; no attempt is made to combine existing rows.
  """

  def up do
    alter table(:flow_logs) do
      add(:outers, :map)
    end

    flush()

    execute("""
    UPDATE flow_logs
    SET outers = jsonb_build_array(
      jsonb_build_object(
        'src_ip', host(outer_src_ip),
        'src_port', outer_src_port,
        'dst_ip', host(outer_dst_ip),
        'dst_port', outer_dst_port
      )
    )
    """)

    alter table(:flow_logs) do
      modify(:outers, :map, null: false)
    end

    drop(constraint(:flow_logs, :flow_logs_ports_in_range))

    alter table(:flow_logs) do
      remove(:outer_src_ip)
      remove(:outer_src_port)
      remove(:outer_dst_ip)
      remove(:outer_dst_port)
    end

    create(
      constraint(:flow_logs, :flow_logs_ports_in_range,
        check: "inner_src_port BETWEEN 0 AND 65535 AND inner_dst_port BETWEEN 0 AND 65535"
      )
    )

    create(
      constraint(:flow_logs, :flow_logs_outers_non_empty,
        check: """
        jsonb_typeof(outers) = 'array' AND
        jsonb_array_length(outers) > 0 AND
        NOT jsonb_path_exists(
          outers,
          '$[*] ? ((@.src_ip == null && @.src_port != null) ||
                   (@.src_ip != null && @.src_port == null))'
        )
        """
      )
    )
  end

  def down do
    raise "The ordered outers migration cannot be reversed without discarding paths"
  end
end
