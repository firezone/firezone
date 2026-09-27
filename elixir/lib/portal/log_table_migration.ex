defmodule Portal.LogTableMigration do
  @moduledoc """
  Operator entry points for the final log-table migration. Backfill is bounded
  and resumable; cutover and legacy cleanup must be explicitly requested.
  """
  alias __MODULE__.Database

  def status, do: Database.status()
  def step(source, batch_size \\ 500), do: Database.step(source, batch_size)
  def cutover(source), do: Database.cutover(source)
  def cleanup(source), do: Database.cleanup(source)

  defmodule Database do
    alias Portal.Safe

    @sources ~w[session_logs api_request_logs change_logs]
    @cutoff "((clock_timestamp() AT TIME ZONE 'UTC')::date - 121)::timestamp AT TIME ZONE 'UTC'"

    def status do
      query!("SELECT to_jsonb(b) - 'context' FROM log_table_backfills b ORDER BY source_table").rows
      |> Enum.map(fn [state] -> state end)
    end

    def step(source, batch_size) when source in @sources and batch_size in 1..2000 do
      transaction(source, fn ->
        if partitioned?(source) do
          :cutover
        else
          # Serialize the source schema/trigger with this batch as well as
          # maintenance/cutover. DML remains allowed; copied rows are locked below.
          query!("LOCK TABLE ONLY #{source} IN ROW SHARE MODE")
          context = context!(source)
          initialize(source, context)
          run_phase(source, state(source), batch_size)
        end
      end)
    end

    def cutover(source) when source in @sources do
      transaction(source, fn ->
        if partitioned?(source), do: :already_cut_over, else: do_cutover(source)
      end)
    end

    def cleanup(source) when source in @sources do
      transaction(source, fn -> do_cleanup(source) end)
    end

    defp do_cleanup(source) do
      state = state(source)
      unless state["phase"] == "cutover", do: raise("#{source} has not been cut over")
      [[canonical_oid]] = query!("SELECT to_regclass($1)::oid", [source]).rows

      unless canonical_oid == state["context"]["mirror_oid"],
        do: raise("Unexpected canonical table #{source}")

      legacy = source <> "_legacy"
      [[oid]] = query!("SELECT to_regclass($1)::oid", [legacy]).rows

      if oid do
        unless oid == state["context"]["source_oid"],
          do: raise("Unexpected legacy table #{legacy}")

        # No CASCADE: unexpected external dependencies must block cleanup.
        query!("DROP TABLE #{legacy}")
        query!("DROP FUNCTION mirror_#{source}()")
      end

      query!(
        "UPDATE log_table_backfills SET legacy_dropped_at = COALESCE(legacy_dropped_at, clock_timestamp()) WHERE source_table = $1",
        [source]
      )

      :cleaned_up
    end

    defp transaction(source, fun) do
      {:ok, result} =
        Safe.transact(
          fn ->
            query!("SET LOCAL lock_timeout = '1s'")
            query!("SET LOCAL statement_timeout = '10s'")
            # Same stable key used by PartitionLogTables, before and after rename.
            [[locked]] =
              query!(
                "SELECT pg_try_advisory_xact_lock(hashtextextended(current_schema() || '.' || $1, 0))",
                [source <> "_partitioned"]
              ).rows

            {:ok, if(locked, do: fun.(), else: :busy)}
          end,
          timeout: 120_000
        )

      result
    end

    defp context!(source) do
      mirror = source <> "_partitioned"

      case query!(
             """
             SELECT jsonb_build_object(
               'source_oid', s.oid::bigint, 'mirror_oid', m.oid::bigint, 'activation', a.started_at,
               'trigger', pg_get_triggerdef(t.oid), 'function', pg_get_functiondef(t.tgfoid))
             FROM log_partition_mirrors a
             JOIN pg_class s ON s.oid = to_regclass(a.source_table) AND s.relkind = 'r'
             JOIN pg_class m ON m.oid = to_regclass(a.source_table || '_partitioned') AND m.relkind = 'p'
             JOIN pg_trigger t ON t.tgrelid = s.oid AND t.tgname = 'mirror_partitioned_logs'
               AND t.tgenabled = 'O' AND NOT t.tgisinternal
               AND t.tgfoid = to_regprocedure('mirror_' || a.source_table || '()')
             WHERE a.source_table = $1
             """,
             [source]
           ).rows do
        [[context]] ->
          unless String.contains?(context["function"], "::date - 121"),
            do:
              raise(
                "#{source} needs the 121-day retention manual migration before backfill or cutover"
              )

          shape = shape(source)

          unless shape == shape(mirror),
            do: raise("#{source} and its mirror have different columns/defaults")

          Map.put(context, "shape", shape)

        [] ->
          raise "#{source} is not actively mirrored; run the manual migrations before starting backfill"
      end
    end

    defp shape(table) do
      [[shape]] =
        query!(
          """
          SELECT jsonb_agg(jsonb_build_array(a.attname, a.atttypid, a.atttypmod, a.attnotnull,
                                            pg_get_expr(d.adbin, d.adrelid)) ORDER BY a.attnum)
          FROM pg_attribute a LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
          WHERE a.attrelid = $1::text::regclass AND a.attnum > 0 AND NOT a.attisdropped
          """,
          [table]
        ).rows

      shape
    end

    defp initialize(source, context) do
      # A repaired trigger, changed activation marker, or schema change starts a
      # fresh pass. Never reuse readiness across an interruption of mirroring.
      query!("DELETE FROM log_table_backfills WHERE source_table = $1 AND context <> $2::jsonb", [
        source,
        context
      ])

      query!(
        """
        INSERT INTO log_table_backfills (source_table, context, phase, upper_account_id, upper_log_id)
        SELECT $1, $2::jsonb, 'copy', last.account_id, last.log_id
        FROM (SELECT 1) seed LEFT JOIN LATERAL (
          SELECT account_id, log_id FROM #{source} ORDER BY account_id DESC, log_id DESC LIMIT 1
        ) last ON true
        ON CONFLICT (source_table) DO NOTHING
        """,
        [source, context]
      )
    end

    defp state(source) do
      case query!(
             "SELECT to_jsonb(b) FROM log_table_backfills b WHERE source_table = $1 FOR UPDATE",
             [source]
           ).rows do
        [[state]] -> state
        [] -> raise "No backfill state for #{source}"
      end
    end

    defp run_phase(source, %{"phase" => "copy"} = state, limit) do
      columns = Enum.map(state["context"]["shape"], fn [name | _] -> quote_identifier(name) end)
      names = Enum.join(columns, ", ")
      values = Enum.map_join(columns, ", ", &("EXCLUDED." <> &1))
      existing = Enum.map_join(columns, ", ", &("destination." <> &1))

      conflict =
        if source == "change_logs",
          do: "timestamp, lsn",
          else: "account_id, #{timestamp(source)}, log_id"

      # FOR UPDATE, deliberately without SKIP LOCKED: a locked old row must
      # never be skipped permanently as the persisted cursor advances. Locks
      # serialize this snapshot with MCP updates, retention and FK cascades.
      result =
        query!(
          """
          WITH batch AS MATERIALIZED (
            SELECT s.* FROM #{source} s
            WHERE #{cursor_predicate(state)}
            ORDER BY s.account_id, s.log_id LIMIT $1 FOR UPDATE OF s
          ), copied AS (
            INSERT INTO #{source}_partitioned AS destination (#{names}) SELECT #{names} FROM batch
            WHERE #{timestamp(source)} >= #{@cutoff}
            ON CONFLICT (#{conflict}) DO UPDATE SET (#{names}) = ROW(#{values})
            WHERE ROW(#{existing}) IS DISTINCT FROM ROW(#{values})
          )
          SELECT account_id, log_id FROM batch ORDER BY account_id DESC, log_id DESC
          """,
          cursor_params(state, limit)
        )

      advance(source, result.rows, "scanned_rows", "verify_source", source)
    end

    defp run_phase(source, %{"phase" => phase} = state, limit)
         when phase in ["verify_source", "verify_mirror"] do
      {table, other, next_phase, next_table} =
        if phase == "verify_source",
          do: {source, source <> "_partitioned", "verify_mirror", source <> "_partitioned"},
          else: {source <> "_partitioned", source, "analyze", source}

      # One statement snapshot compares both copies, so a concurrently committed
      # insert/update/delete cannot create a false mismatch between queries.
      result =
        query!(
          """
          WITH batch AS MATERIALIZED (
            SELECT DISTINCT s.account_id, s.log_id FROM #{table} s
            WHERE #{cursor_predicate(state)}
            ORDER BY s.account_id, s.log_id LIMIT $1
          )
          SELECT b.account_id, b.log_id,
            NOT EXISTS (
              SELECT 1 FROM #{table} s
              WHERE s.account_id = b.account_id AND s.log_id = b.log_id
                AND s.#{timestamp(source)} >= #{@cutoff}
                AND NOT EXISTS (
                  SELECT 1 FROM #{other} original
                  WHERE original.account_id = s.account_id AND original.log_id = s.log_id
                    AND original.#{timestamp(source)} = s.#{timestamp(source)}
                    AND to_jsonb(original) = to_jsonb(s)))
          FROM batch b ORDER BY b.account_id DESC, b.log_id DESC
          """,
          cursor_params(state, limit)
        )

      unless Enum.all?(result.rows, fn [_, _, matches] -> matches end),
        do:
          raise(
            "#{source} mirror verification failed; investigate divergent or extra rows before cutover"
          )

      advance(
        source,
        Enum.map(result.rows, &Enum.take(&1, 2)),
        "verified_rows",
        next_phase,
        next_table
      )
    end

    defp run_phase(source, %{"phase" => "analyze"}, _limit) do
      # Parent statistics aren't automatically maintained like ordinary tables.
      # Do this outside the short cutover transaction, with a separate budget.
      query!("SET LOCAL statement_timeout = '110s'")
      query!("ANALYZE #{source}_partitioned", [], timeout: 115_000)

      query!(
        "UPDATE log_table_backfills SET phase = 'ready', ready_at = clock_timestamp() WHERE source_table = $1",
        [source]
      )

      :ready
    end

    defp run_phase(_source, %{"phase" => "ready"}, _limit), do: :ready

    defp cursor_predicate(state) do
      upper = "(s.account_id, s.log_id) <= ($2::text::uuid, $3::text::bytea)"

      if state["cursor_account_id"] do
        upper <> " AND (s.account_id, s.log_id) > ($4::text::uuid, $5::text::bytea)"
      else
        upper <> " AND $4::text IS NULL AND $5::text IS NULL"
      end
    end

    defp cursor_params(state, limit),
      do: [
        limit,
        state["upper_account_id"],
        state["upper_log_id"],
        state["cursor_account_id"],
        state["cursor_log_id"]
      ]

    defp advance(source, [], _counter, next_phase, next_table) do
      query!(
        """
        UPDATE log_table_backfills SET phase = $2, cursor_account_id = NULL, cursor_log_id = NULL,
          (upper_account_id, upper_log_id) = (
            SELECT account_id, log_id FROM #{next_table} ORDER BY account_id DESC, log_id DESC LIMIT 1
          )
        WHERE source_table = $1
        """,
        [source, next_phase]
      )

      :progress
    end

    defp advance(source, [[account_id, log_id] | _] = rows, counter, _next_phase, _next_table) do
      query!(
        "UPDATE log_table_backfills SET cursor_account_id = $2, cursor_log_id = $3, #{counter} = #{counter} + $4 WHERE source_table = $1",
        [source, account_id, log_id, length(rows)]
      )

      :progress
    end

    defp do_cutover(source) do
      mirror = source <> "_partitioned"
      legacy = source <> "_legacy"
      # ONLY avoids recursively locking hundreds of partitions. All supported
      # readers/writers route through these parents and acquire parent locks.
      query!("LOCK TABLE ONLY #{source}, ONLY #{mirror} IN ACCESS EXCLUSIVE MODE")
      state = state(source)

      unless state["phase"] == "ready" and state["context"] == context!(source),
        do:
          raise(
            "#{source} is not verified with the current mirror configuration; resume backfill first"
          )

      check_dependencies!(source)
      [[sequence]] = query!("SELECT pg_get_serial_sequence($1, 'seq')", [source]).rows
      unless sequence, do: raise("#{source}.seq has no owned sequence")

      [[sequence_schema, sequence_name]] =
        query!(
          "SELECT n.nspname, c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE c.oid = $1::text::regclass",
          [sequence]
        ).rows

      query!("ALTER TABLE #{source} RENAME TO #{legacy}")
      query!("ALTER TABLE #{mirror} RENAME TO #{source}")

      query!(
        "ALTER SEQUENCE #{quote_identifier(sequence_schema)}.#{quote_identifier(sequence_name)} OWNED BY #{source}.seq"
      )

      # Preserve a forward bridge for statements already bound to the legacy
      # relation during cutover. Normal writes go directly to the new parent.
      function = state["context"]["function"] |> String.replace(mirror, source)
      query!(function)

      query!(
        "UPDATE log_table_backfills SET phase = 'cutover', cutover_at = clock_timestamp() WHERE source_table = $1",
        [source]
      )

      :cutover
    end

    defp check_dependencies!(source) do
      [[blocked]] =
        query!(
          """
          SELECT EXISTS (SELECT 1 FROM pg_constraint WHERE confrelid = $1::text::regclass)
            OR EXISTS (SELECT 1 FROM pg_depend d JOIN pg_rewrite r ON d.classid = 'pg_rewrite'::regclass AND d.objid = r.oid
                       WHERE d.refobjid = $1::text::regclass)
            OR EXISTS (SELECT 1 FROM pg_publication_tables WHERE schemaname = current_schema() AND tablename = $1)
          """,
          [source]
        ).rows

      if blocked,
        do:
          raise(
            "#{source} has foreign-key, view, or publication dependencies; migrate them before cutover"
          )
    end

    defp partitioned?(source) do
      query!(
        "SELECT EXISTS (SELECT 1 FROM pg_partitioned_table WHERE partrelid = to_regclass($1))",
        [source]
      ).rows == [[true]]
    end

    defp timestamp("api_request_logs"), do: "inserted_at"
    defp timestamp(_source), do: "timestamp"
    defp quote_identifier(name), do: ~s("#{String.replace(name, "\"", "\"\"")}")

    defp query!(sql, params \\ [], opts \\ []) do
      case Safe.unscoped() |> Safe.query(sql, params, opts) do
        {:ok, result} -> result
        {:error, error} -> raise error
      end
    end
  end
end
