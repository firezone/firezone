defmodule Portal.Repo.Migrations.NormalizeAccountsTimestamps do
  use Ecto.Migration

  @moduledoc """
  Converts this table's `timestamp without time zone` columns to timestamptz,
  one migration per table so each ACCESS EXCLUSIVE lock is acquired and
  released in its own transaction (a lock stall affects one table for at most
  lock_timeout, already-converted tables stay committed, and schema_migrations
  is the resume cursor on failure).

  All stored values are UTC instants (Elixir writes UTC through binary
  params, and the DB-side `now()` defaults ran under a UTC server timezone),
  so the conversion is a semantic no-op reinterpretation. SET LOCAL
  timezone = UTC inside the migration transaction is load-bearing twice
  over: it makes the timestamp -> timestamptz cast the identity (a non-UTC
  session would reinterpret every stored value as local time), and on
  Postgres >= 12 it lets ALTER TYPE skip the table rewrite entirely, making
  the ALTER a metadata-only change. The transaction guarantees every
  statement runs on the one connection the SET LOCAL applies to, regardless
  of connection pooling.

  Excluded from the series: oban_jobs / oban_peers (Oban manages its own
  schema) and schema_migrations (Ecto-managed).
  """

  def up do
    convert("timestamptz")
  end

  def down do
    convert("timestamp")
  end

  defp convert(target_type) do
    execute("SET LOCAL timezone TO 'UTC'")
    execute("SET LOCAL lock_timeout TO '5s'")

    execute(~s|ALTER TABLE "accounts" ALTER COLUMN "disabled_at" TYPE #{target_type}, ALTER COLUMN "inserted_at" TYPE #{target_type}, ALTER COLUMN "lock_enabled_at" TYPE #{target_type}, ALTER COLUMN "scheduled_deletion_at" TYPE #{target_type}, ALTER COLUMN "updated_at" TYPE #{target_type}, ALTER COLUMN "warning_last_sent_at" TYPE #{target_type}|)
  end
end
