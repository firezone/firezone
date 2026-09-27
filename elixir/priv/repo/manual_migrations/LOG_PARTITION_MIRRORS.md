# Log partition mirrors: first rollout

This phase creates `session_logs_partitioned`, `api_request_logs_partitioned`,
and `change_logs_partitioned`. All application reads still use the original
tables. There is no backfill, table rename, automatic read cutover, or removal
of the original retention indexes/jobs in this release.

## Activation

Deploy the release normally. The new worker is a no-op until the manual
migration activates each mirror. The API request schema's additional timestamp
predicate works with the original table before activation.

From the release IEx shell, use the existing convention:

```elixir
Portal.Release.migrate(manual: true)
```

This runs all pending manual migrations; inspect the pending migrations first.
The new migration is `20260927000000_create_log_partition_mirrors.exs`.

It prepares each replacement, its indexes, its account cascade FK, and daily
UTC partitions from 90 days ago through 14 days ahead. Then it installs an
`AFTER INSERT OR UPDATE OR DELETE` trigger on the original table and records
the activation timestamp in the same transaction. The trigger covers old and
new application instances, and copies the stored `seq`, timestamps, and IDs
without allocating a second sequence value. Both writes commit or roll back
together. MCP updates and account-deletion cascades are mirrored too.

Each DDL operation commits separately and uses a one-second `lock_timeout`.
If it cannot acquire a lock, rerun the migration after investigating the
blocker. Completed setup is reused; already-activated streams continue
mirroring and their coverage timestamps are preserved. There is no historical
scan, index build on an existing log table, or data copy during activation.

Check activation in PostgreSQL:

```sql
SELECT source_table, started_at
FROM log_partition_mirrors
ORDER BY source_table;

SELECT tgrelid::regclass, tgenabled
FROM pg_trigger
WHERE tgname = 'mirror_partitioned_logs';
```

Expect three activation rows and three enabled triggers. Exercise a session,
a REST request, and an MCP tool call and compare both copies by account/log ID,
including `seq` and MCP metadata. Monitor insert/update latency, WAL volume,
replica lag, disk growth, and Oban failures during the rollout: synchronous
mirroring adds write work, and a mirror failure intentionally fails the source
write rather than silently creating a coverage gap.

## Retention and coverage

`Portal.Workers.PartitionLogTables` runs daily at 03:30 UTC. It also maintains
flow logs with their existing 121-day retention window. For mirrors, it maintains the
90-day boundary through 14 days ahead using ATTACH and DETACH CONCURRENTLY,
recovers interrupted detach/drop operations, and serializes runs with an
advisory lock. It does not run cutover. The full UTC boundary day is retained;
there may be up to 91 daily historical partitions plus the future buffer.

Keep the existing legacy DELETE workers running. Their deletes also remove
mirror rows, so existing retention semantics remain intact during this phase.
Mirror triggers skip rows older than the retained boundary day, including old
WAL replays. Future writes beyond the pre-created window fail; there is no
default partition that could hide a stopped maintainer. Alert on worker
failures before the lookahead buffer runs out.

The activation timestamp is a coverage lower bound, not proof of equivalence.
After at least a full retention window of continuous mirroring, historical
rows predating activation should have aged out. Before a later cutover, verify
that no retained source rows are missing or different (including future-dated
rows that might have been inserted before activation). Alternatively, a
separate concurrency-safe backfill can make the mirror ready sooner. Do not
backfill with an unsynchronized INSERT SELECT while updates/deletes are live.

Change-log ingestion retains `ON CONFLICT (lsn)` on the original table. Its
trigger uses `(timestamp, lsn)` on the partitioned mirror, where `timestamp`
is the original WAL commit timestamp. The final cutover must switch the
consumer's conflict target to that composite key. Public log IDs can change
on replay, so they are not the replay-deduplication key.

Before dropping the originals in a later release, transfer ownership of each
shared `*_seq_seq` sequence to the replacement. Preserve log-sink cursors and
sequence values. Any intervening log schema migrations must update both table
shapes together: the mirror trigger copies the complete stored row.

## Rollback before cutover

Application rollback alone leaves database mirroring active and is compatible
with the old release. To remove the extra writes, roll back this manual
migration too. Its `down/0` removes triggers before removing mirror tables;
the original rows, sequence ownership, and read paths remain intact. Coordinate
this with partition maintenance so it is not running during rollback.

For a release whose latest manual migration is still this one:

```elixir
path = Application.app_dir(:portal, "priv/repo/manual_migrations/20260927000000_create_log_partition_mirrors.exs")
Code.require_file(path)
Ecto.Migrator.with_repo(Portal.Repo, fn repo ->
  Ecto.Migrator.down(repo, 20260927000000, Portal.Repo.Migrations.CreateLogPartitionMirrors)
end)
```

Reactivating after rollback starts a new coverage window. This rollback is only
valid for the mirror phase; after switching reads/writes, reverting requires a
separate plan to preserve writes accepted by the replacement.

If activation failed partway through, Ecto has not yet recorded the migration,
so `Ecto.Migrator.down/3` will not execute it. Normally, rerun `migrate` to finish
setup. To stop partially activated mirroring instead, disable the source
triggers and clear their coverage markers together:

```sql
BEGIN;
SET LOCAL lock_timeout = '1s';
DROP TRIGGER IF EXISTS mirror_partitioned_logs ON session_logs;
DROP TRIGGER IF EXISTS mirror_partitioned_logs ON api_request_logs;
DROP TRIGGER IF EXISTS mirror_partitioned_logs ON change_logs;
DELETE FROM log_partition_mirrors;
COMMIT;
```

This leaves the original tables serving traffic and the partial replacements
available for a later retry. Rerunning the incomplete migration reactivates
mirroring with new coverage timestamps. Do not disable triggers without also
invalidating the coverage markers.
