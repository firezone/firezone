defmodule Portal.Ops.RegionTransfer do
  @moduledoc """
  Moves one account between Firezone Cloud regions.

  `export/2` disables the account and writes every row it owns to a directory,
  one PostgreSQL COPY file per table plus a manifest. `import/1` loads that
  directory into the database of the other region in one transaction, and
  `enable/1` turns the account back on once the move is verified. The runbook
  in the infra repository, README-region-transfer.md, lists the steps around
  these calls.

  The log tables are not moved. They stay in the source region until the
  account is deleted there, which cascades to them.
  """
  alias __MODULE__.Database
  alias Portal.Mailer
  alias Portal.Mailer.Notifications
  require Logger

  @disabled_reason "Region transfer in progress"
  @manifest "manifest.json"
  @region_names %{us: "United States", eu: "European Union"}

  # Session state that users recreate by signing in, rows the account disable
  # hook deletes anyway, OAuth state bound to this region's clients, and the
  # log tables, which are deleted with the account in the source region.
  @skipped_tables ~w(api_request_logs change_logs client_tokens feedback_submissions flow_logs oauth_authorization_codes oauth_grants oauth_tokens one_time_passcodes policy_authorizations portal_sessions session_logs)

  @doc "Disables the account and exports it to `dir`."
  # sobelow_skip ["Traversal.FileModule"]
  def export(account_id, dir) do
    account = Database.fetch_account!(account_id)

    tables = Database.list_account_tables() -- @skipped_tables
    {ordered, deferred} = order_tables(tables, Database.foreign_keys(tables))
    counts = Map.new(ordered, &{&1, Database.count_rows(&1, account.id)})

    print_summary("Export", account, Enum.map(ordered, &{&1, counts[&1]}))
    IO.puts("Skipped: #{Enum.join(@skipped_tables, ", ")}")

    if confirm?("Disable the account and export it to #{dir}? [y/N]") do
      File.mkdir_p!(dir)
      {:ok, account} = Database.disable_account(account, @disabled_reason)
      notify_admins(account, &Notifications.region_transfer_started_email(&1, &2, other_region_name()))

      account_columns = Database.columns("accounts")
      1 = Database.copy_out("accounts", account_columns, "id", account.id, Path.join(dir, "accounts.copy"))

      tables =
        Enum.map(ordered, fn table ->
          columns = Database.columns(table)
          rows = Database.copy_out(table, columns, "account_id", account.id, Path.join(dir, "#{table}.copy"))

          %{
            "name" => table,
            "columns" => columns,
            "rows" => rows,
            "deferred_columns" => Map.get(deferred, table, [])
          }
        end)

      manifest = %{
        "account_id" => account.id,
        "name" => account.name,
        "slug" => account.slug,
        "schema_version" => Database.schema_version(),
        "exported_at" => DateTime.to_iso8601(DateTime.utc_now()),
        "account_columns" => account_columns,
        "tables" => tables
      }

      File.write!(Path.join(dir, @manifest), Jason.encode!(manifest, pretty: true))

      IO.puts("Exported #{total_rows(manifest)} rows to #{dir}. The account is disabled.")
      {:ok, manifest}
    else
      IO.puts("Aborted.")
      :aborted
    end
  end

  @doc """
  Imports an account exported by `export/3` from `dir`. The account stays
  disabled until `enable/1` runs.
  """
  # sobelow_skip ["Traversal.FileModule"]
  def import(dir) do
    manifest = dir |> Path.join(@manifest) |> File.read!() |> Jason.decode!()
    local_version = Database.schema_version()

    cond do
      manifest["schema_version"] != local_version ->
        {:error, {:schema_version_mismatch, exported: manifest["schema_version"], local: local_version}}

      Database.account_exists?(manifest["account_id"]) ->
        {:error, :account_exists}

      Database.slug_taken?(manifest["slug"]) ->
        {:error, :slug_taken}

      true ->
        confirm_import(dir, manifest)
    end
  end

  @doc "Turns an imported account back on and tells its admins."
  def enable(account_id) do
    with {:ok, account} <- account_id |> Database.fetch_account!() |> Database.enable_account() do
      notify_admins(account, &Notifications.region_transfer_completed_email(&1, &2, region_name()))
      {:ok, account}
    end
  end

  defp notify_admins(account, build_email) do
    case Database.list_admin_emails(account.id) do
      [] ->
        Logger.warning("No admins to notify about the region transfer", account_id: account.id)

      admin_emails ->
        case account |> build_email.(admin_emails) |> Mailer.enqueue() do
          {:ok, _job} -> :ok
          {:error, reason} -> Logger.error("Failed to enqueue region transfer email", account_id: account.id, reason: inspect(reason))
        end
    end
  end

  defp region_name, do: Map.fetch!(@region_names, Portal.Config.fetch_env!(:portal, :data_residency_region))

  defp other_region_name do
    case Portal.Config.fetch_env!(:portal, :data_residency_region) do
      :us -> @region_names.eu
      :eu -> @region_names.us
    end
  end

  defp confirm_import(dir, manifest) do
    rows = Enum.map(manifest["tables"], &{&1["name"], &1["rows"]})
    print_summary("Import", manifest, rows)

    if confirm?("Import #{total_rows(manifest)} rows from #{dir}? [y/N]") do
      case Database.import_tables(dir, manifest) do
        {:ok, imported} ->
          IO.puts("Imported #{imported} rows. The account stays disabled until enable/1 runs.")
          {:ok, manifest}

        {:error, reason} ->
          IO.puts("Import failed and was rolled back: #{inspect(reason)}")
          {:error, reason}
      end
    else
      IO.puts("Aborted.")
      :aborted
    end
  end

  defp total_rows(manifest), do: manifest["tables"] |> Enum.map(& &1["rows"]) |> Enum.sum()

  defp print_summary(action, account, rows) do
    IO.puts("#{action} of account #{account_field(account, :name)} (#{account_field(account, :slug)}, #{account_field(account, :id)})")

    for {table, count} <- rows, count > 0 do
      IO.puts("  #{String.pad_trailing(table, 40)} #{count}")
    end
  end

  defp account_field(%{"account_id" => _} = manifest, :id), do: manifest["account_id"]
  defp account_field(%{"account_id" => _} = manifest, field), do: manifest[Atom.to_string(field)]
  defp account_field(account, field), do: Map.fetch!(account, field)

  defp confirm?(prompt) do
    IO.puts(prompt)
    IO.gets("") |> String.trim() |> String.downcase() == "y"
  end

  # Kahn's algorithm over the foreign keys between the exported tables. When
  # only cycles remain, a foreign key with nullable columns is cut: those
  # columns are imported as NULL and restored once every table is in.
  defp order_tables(tables, foreign_keys) do
    deps =
      Map.new(tables, fn table ->
        {table, for({^table, ref, _nullable} <- foreign_keys, ref != table, uniq: true, do: ref)}
      end)

    do_order(Enum.sort(tables), deps, foreign_keys, [], %{})
  end

  defp do_order([], _deps, _foreign_keys, ordered, deferred), do: {Enum.reverse(ordered), deferred}

  defp do_order(remaining, deps, foreign_keys, ordered, deferred) do
    case Enum.filter(remaining, fn table -> Enum.all?(deps[table], &(&1 not in remaining)) end) do
      [] ->
        {table, ref, columns} = cut_cycle(remaining, foreign_keys)
        deps = Map.update!(deps, table, &List.delete(&1, ref))
        deferred = Map.update(deferred, table, columns, &Enum.uniq(&1 ++ columns))
        do_order(remaining, deps, foreign_keys, ordered, deferred)

      ready ->
        do_order(remaining -- ready, deps, foreign_keys, Enum.reverse(ready) ++ ordered, deferred)
    end
  end

  defp cut_cycle(remaining, foreign_keys) do
    Enum.find(foreign_keys, fn {table, ref, nullable} ->
      table in remaining and ref in remaining and table != ref and nullable != []
    end) ||
      raise "cannot order tables, the cycle among #{inspect(remaining)} has no nullable foreign key"
  end

  defmodule Database do
    import Ecto.Query
    alias Portal.Account
    alias Portal.Safe

    def fetch_account!(id) do
      from(a in Account, where: a.id == ^id)
      |> Safe.unscoped()
      |> Safe.one!()
    end

    def account_exists?(id) do
      from(a in Account, where: a.id == ^id, select: a.id)
      |> Safe.unscoped()
      |> Safe.one() != nil
    end

    def slug_taken?(slug) do
      from(a in Account, where: a.slug == ^slug, select: a.id)
      |> Safe.unscoped()
      |> Safe.one() != nil
    end

    def list_admin_emails(account_id) do
      from(a in Portal.Actor,
        where: a.account_id == ^account_id,
        where: a.type == :account_admin_user,
        where: a.is_disabled == false,
        select: a.email
      )
      |> Safe.unscoped()
      |> Safe.all()
    end

    def disable_account(%Account{is_disabled: true} = account, _reason), do: {:ok, account}

    def disable_account(%Account{} = account, reason) do
      account
      |> Ecto.Changeset.change(is_disabled: true, disabled_reason: reason)
      |> Safe.unscoped()
      |> Safe.update()
    end

    def enable_account(%Account{} = account) do
      account
      |> Ecto.Changeset.change(is_disabled: false, disabled_reason: nil)
      |> Safe.unscoped()
      |> Safe.update()
    end

    def schema_version do
      %{rows: [[version]]} = query!("SELECT max(version) FROM schema_migrations", [])
      version
    end

    # Partition parents stand in for their partitions.
    def list_account_tables do
      %{rows: rows} =
        query!(
          """
          SELECT c.relname
          FROM pg_class c
          JOIN pg_namespace n ON n.oid = c.relnamespace
          WHERE n.nspname = 'public'
            AND c.relkind IN ('r', 'p')
            AND NOT c.relispartition
            AND c.relname <> 'accounts'
            AND EXISTS (
              SELECT 1 FROM pg_attribute a
              WHERE a.attrelid = c.oid AND a.attname = 'account_id' AND NOT a.attisdropped
            )
          ORDER BY c.relname
          """,
          []
        )

      Enum.map(rows, &hd/1)
    end

    # Foreign keys between the given tables as `{table, referenced_table,
    # nullable_columns}`. A nullable column makes the key skippable on import.
    def foreign_keys(tables) do
      %{rows: rows} =
        query!(
          """
          SELECT c.conrelid::regclass::text,
                 c.confrelid::regclass::text,
                 COALESCE(array_agg(a.attname::text ORDER BY k.ord) FILTER (WHERE NOT a.attnotnull), '{}')
          FROM pg_constraint c
          JOIN LATERAL unnest(c.conkey) WITH ORDINALITY AS k(attnum, ord) ON true
          JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = k.attnum
          WHERE c.contype = 'f'
            AND c.conrelid::regclass::text = ANY($1)
            AND c.confrelid::regclass::text = ANY($1)
          GROUP BY c.oid, c.conrelid, c.confrelid
          ORDER BY 1, 2
          """,
          [tables]
        )

      Enum.map(rows, &List.to_tuple/1)
    end

    def columns(table) do
      %{rows: rows} =
        query!(
          """
          SELECT column_name FROM information_schema.columns
          WHERE table_schema = 'public' AND table_name = $1
          ORDER BY ordinal_position
          """,
          [table]
        )

      Enum.map(rows, &hd/1)
    end

    def count_rows(table, account_id) do
      %{rows: [[count]]} =
        query!(~s[SELECT count(*) FROM #{ident(table)} WHERE account_id = $1], [Ecto.UUID.dump!(account_id)])

      count
    end

    # sobelow_skip ["Traversal.FileModule"]
    def copy_out(table, columns, where_column, account_id, path) do
      {:ok, account_id} = Ecto.UUID.cast(account_id)

      sql =
        ~s[COPY (SELECT #{idents(columns)} FROM #{ident(table)} WHERE #{ident(where_column)} = '#{account_id}') TO STDOUT]

      {:ok, rows} =
        Safe.transact(fn ->
          File.open!(path, [:write, :binary], &{:ok, copy_to_file(sql, &1)})
        end)

      rows
    end

    defp copy_to_file(sql, file) do
      Safe.unscoped()
      |> Safe.sql_stream(sql, [])
      |> Enum.reduce(0, fn %Postgrex.Result{rows: chunks}, rows -> write_chunks(file, chunks, rows) end)
    end

    defp write_chunks(file, chunks, rows) do
      Enum.reduce(chunks, rows, fn chunk, rows ->
        IO.binwrite(file, chunk)
        rows + length(:binary.matches(chunk, "\n"))
      end)
    end

    def import_tables(dir, manifest) do
      Safe.transact(fn ->
        copy_in("accounts", manifest["account_columns"], Path.join(dir, "accounts.copy"))

        staged = Enum.flat_map(manifest["tables"], &import_table(dir, &1))

        Enum.each(staged, fn {table, staging, deferred_columns} ->
          restore_deferred(table, staging, deferred_columns)
        end)

        verify_counts(manifest)
      end)
    end

    defp import_table(dir, %{"name" => name, "columns" => columns, "deferred_columns" => []}) do
      copy_in(name, columns, Path.join(dir, "#{name}.copy"))
      []
    end

    defp import_table(dir, %{"name" => name, "columns" => columns, "deferred_columns" => deferred}) do
      staging = stage(name)
      copy_in(staging, columns, Path.join(dir, "#{name}.copy"))
      insert_from_staging(name, staging, columns, deferred)
      [{name, staging, deferred}]
    end

    defp verify_counts(manifest) do
      Enum.reduce_while(manifest["tables"], {:ok, 0}, fn table, {:ok, total} ->
        expected = table["rows"]

        case count_rows(table["name"], manifest["account_id"]) do
          ^expected -> {:cont, {:ok, total + expected}}
          count -> {:halt, {:error, {:row_count_mismatch, table["name"], expected: expected, actual: count}}}
        end
      end)
    end

    # sobelow_skip ["Traversal.FileModule"]
    defp copy_in(table, columns, path) do
      stream = Safe.unscoped() |> Safe.sql_stream(~s[COPY #{ident(table)} (#{idents(columns)}) FROM STDIN], [])
      path |> File.stream!(64 * 1024) |> Enum.into(stream)
    end

    defp stage(table) do
      staging = "region_transfer_#{table}"
      query!(~s[DROP TABLE IF EXISTS #{ident(staging)}], [])
      query!(~s[CREATE TEMP TABLE #{ident(staging)} (LIKE #{ident(table)}) ON COMMIT DROP], [])
      staging
    end

    defp insert_from_staging(table, staging, columns, deferred_columns) do
      select = Enum.map_join(columns, ", ", &if(&1 in deferred_columns, do: "NULL", else: ident(&1)))
      query!(~s[INSERT INTO #{ident(table)} (#{idents(columns)}) SELECT #{select} FROM #{ident(staging)}], [])
    end

    defp restore_deferred(table, staging, deferred_columns) do
      set = Enum.map_join(deferred_columns, ", ", &"#{ident(&1)} = s.#{ident(&1)}")
      on = Enum.map_join(primary_key(table), " AND ", &"t.#{ident(&1)} = s.#{ident(&1)}")
      query!(~s[UPDATE #{ident(table)} AS t SET #{set} FROM #{ident(staging)} AS s WHERE #{on}], [])
    end

    defp primary_key(table) do
      %{rows: rows} =
        query!(
          """
          SELECT kcu.column_name
          FROM information_schema.table_constraints tc
          JOIN information_schema.key_column_usage kcu
            ON kcu.constraint_name = tc.constraint_name AND kcu.table_schema = tc.table_schema
          WHERE tc.table_schema = 'public' AND tc.table_name = $1 AND tc.constraint_type = 'PRIMARY KEY'
          ORDER BY kcu.ordinal_position
          """,
          [table]
        )

      Enum.map(rows, &hd/1)
    end

    defp idents(columns), do: Enum.map_join(columns, ", ", &ident/1)

    defp ident(name), do: ~s["#{String.replace(name, ~s["], ~s[""])}"]

    defp query!(sql, params) do
      {:ok, result} = Safe.unscoped() |> Safe.query(sql, params)
      result
    end
  end
end
