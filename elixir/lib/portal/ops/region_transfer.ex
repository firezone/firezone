defmodule Portal.Ops.RegionTransfer do
  @moduledoc """
  Moves one account between Firezone Cloud regions.

  A transfer is two calls: `initiate/2` in the source region and `complete/2`
  in the destination. `rollback/2` in the source undoes `initiate/2`. Both
  `complete/2` and `initiate/2` can run again after an error.

  `export/2` disables the account and uploads every row it owns to a blob
  container in the other region, one PostgreSQL COPY file per table plus a
  manifest. `import/2` loads that export into the database of the other region
  in one transaction, and `enable/2` turns the account back on once the move is
  verified. The files exist on this machine only for the duration of each
  call. The runbook in the infra repository, README-region-transfer.md, lists
  the steps around these calls.

  Every function asks for confirmation on the console. Pass `confirm: false`
  to skip the prompt when a script calls it through `bin/portal rpc`.

  The Stripe subscription moves with the account; see
  `Portal.Ops.RegionTransfer.Billing`.

  The log tables are not moved. They stay in the source region until the
  account is deleted there, which cascades to them. The email suppression list
  is shared by every account in a region, so only the suppressed addresses of
  the account's actors and past recipients are copied, and the source keeps
  them.
  """
  alias __MODULE__.Billing
  alias __MODULE__.Database
  alias __MODULE__.Storage
  alias Portal.Mailer
  alias Portal.Mailer.Notifications
  require Logger

  @disabled_reason "Region transfer in progress"
  @manifest "manifest.json"
  @billing "billing.json"
  @region_names %{us: "United States", eu: "European Union"}

  # Session state that users recreate by signing in, tokens signed with this
  # region's keys, OAuth state bound to this region's clients, log sink
  # cursors into logs that stay here (the destination seeds new ones), and the
  # log tables, which are deleted with the account in the source region.
  # Nullable foreign keys from moved tables to these are exported as NULL.
  # Profile photos are not moved: the destination fetches them again, and
  # deleting the source account deletes them here.
  @nulled_columns %{"external_identities" => ["avatar_etag", "avatar_source"]}

  @skipped_tables ~w(api_request_logs change_logs device_tokens feedback_submissions flow_logs log_sink_cursors oauth_authorization_codes oauth_grants oauth_tokens one_time_passcodes pending_identities policy_authorizations portal_sessions session_logs)

  @doc """
  Starts a transfer in the source region. Refuses while the customer owes
  anything in Stripe, then disables and exports the account like `export/2`,
  and sets its subscription to cancel when the paid period ends.
  """
  def initiate(account_id, opts \\ []) do
    account = Database.fetch_account!(account_id)

    with {:ok, billing} <- Billing.snapshot(account),
         :ok <- Billing.nothing_owed(billing),
         {:ok, manifest} <- export(account_id, opts),
         {:ok, _account} <- account_id |> Database.fetch_account!() |> Billing.schedule_source_cancel() do
      if billing do
        IO.puts("""
        To keep the customer's saved card, copy Stripe customer #{billing["customer"]["id"]} to the
        Stripe account of the #{other_region_name()} region with Stripe's Dashboard copy tool
        before complete/2 runs there.
        """)
      end

      {:ok, manifest}
    end
  end

  @doc """
  Finishes a transfer in the destination region: imports the account, moves
  its slugs, creates its subscription, and enables it. Steps that already ran
  are skipped. See `Portal.Ops.RegionTransfer.Billing.migrate/2` for options.
  """
  def complete(account_id, opts \\ []) do
    with :ok <- import_unless_present(account_id, opts),
         {:ok, _moved} <- Portal.SlugRegistry.transfer(account_id, Portal.SlugRegistry.region()),
         :ok <- migrate_unless_done(account_id, opts) do
      enable(account_id, Keyword.put(opts, :confirm, false))
    end
  end

  defp import_unless_present(account_id, opts) do
    if Database.account_exists?(account_id) do
      :ok
    else
      with {:ok, _manifest} <- __MODULE__.import(account_id, opts), do: :ok
    end
  end

  defp migrate_unless_done(account_id, opts) do
    if account_id |> Database.fetch_account!() |> Billing.pending?() do
      with {:ok, _subscription_id} <- Billing.migrate(account_id, opts), do: :ok
    else
      :ok
    end
  end

  @doc """
  Undoes `initiate/2` in the source region: the subscription renews again,
  the slugs point here, and the account is enabled. Delete the imported copy
  in the destination first with `Portal.Ops.delete_disabled_account/1`, which
  also cancels its subscription there.
  """
  def rollback(account_id, opts \\ []) do
    account = Database.fetch_account!(account_id)

    cond do
      not account.is_disabled or account.disabled_reason != @disabled_reason ->
        {:error, {:not_in_transfer, account.disabled_reason}}

      not confirm?(opts, "Is the imported copy in the #{other_region_name()} region deleted? Roll back? [y/N]") ->
        IO.puts("Aborted.")
        :aborted

      true ->
        with {:ok, _account} <- Billing.resume_source(account),
             {:ok, _moved} <- Portal.SlugRegistry.transfer(account_id, Portal.SlugRegistry.region()) do
          enable(account_id, confirm: false, notify: false)
        end
    end
  end

  @doc "Disables the account and uploads it to the other region."
  def export(account_id, opts \\ []) do
    account = Database.fetch_account!(account_id)

    if account.is_disabled and account.disabled_reason != @disabled_reason do
      {:error, {:account_disabled, account.disabled_reason}}
    else
      plan = plan_export()
      counts = Enum.map(plan, &{&1.name, Database.count_rows(&1.name, account.id)})

      print_summary("Export", account, counts)
      IO.puts("Skipped: #{Enum.join(@skipped_tables, ", ")}")

      if confirm?(opts, "Disable the account and export it to the #{other_region_name()} region? [y/N]") do
        disable_and_export(account, plan)
      else
        IO.puts("Aborted.")
        :aborted
      end
    end
  end

  # Stripe is read before the account is disabled, so a Stripe outage does
  # not start a maintenance window.
  defp disable_and_export(account, plan) do
    with {:ok, billing} <- Billing.snapshot(account), do: disable_and_export(account, plan, billing)
  end

  defp disable_and_export(account, plan, billing) do
    {:ok, account} = Database.disable_account(account, @disabled_reason)
    {:ok, account} = Database.put_billing_state(account, Billing.transfer_state(billing, "exported"))
    notify_admins(account, &Notifications.region_transfer_started_email(&1, &2, other_region_name()))

    manifest = with_scratch_dir(&upload_export(&1, account, plan, billing))

    IO.puts("Exported #{total_rows(manifest)} rows. The account is disabled.")
    {:ok, manifest}
  end

  @doc """
  Imports an account that `export/2` uploaded from the other region. The
  account stays disabled until `enable/2` runs.
  """
  def import(account_id, opts \\ []) do
    case Storage.get(:inbox, account_id, @manifest) do
      {:ok, body} -> check_import(Jason.decode!(body), opts)
      {:error, :not_found} -> {:error, :export_not_found}
    end
  end

  defp check_import(manifest, opts) do
    local_version = Database.schema_version()

    cond do
      manifest["schema_version"] != local_version ->
        {:error, {:schema_version_mismatch, exported: manifest["schema_version"], local: local_version}}

      Database.account_exists?(manifest["account_id"]) ->
        {:error, :account_exists}

      (taken = Database.taken_slugs([manifest["slug"] | manifest["slugs"]])) != [] ->
        {:error, {:slugs_taken, taken}}

      true ->
        confirm_import(manifest, opts)
    end
  end

  @doc """
  Turns an account disabled by `export/2` back on. In the destination this
  also emails the admins that the move is done; pass `notify: false` when
  rolling back in the source.

  Refuses while the Stripe billing is not moved. Pass `billing: :skip` only
  for an export made before billing moved with the account.
  """
  def enable(account_id, opts \\ []) do
    account = Database.fetch_account!(account_id)
    billing = Billing.ready?(account, opts)

    cond do
      not account.is_disabled or account.disabled_reason != @disabled_reason ->
        {:error, {:not_in_transfer, account.disabled_reason}}

      billing != :ok ->
        billing

      not confirm?(opts, "Enable account #{account.name} (#{account.slug})? [y/N]") ->
        IO.puts("Aborted.")
        :aborted

      true ->
        {:ok, account} = Database.enable_account(account)

        if Keyword.get(opts, :notify, true) do
          notify_admins(account, &Notifications.region_transfer_completed_email(&1, &2, region_name()))
        end

        {:ok, account}
    end
  end

  # Tables in foreign key order, each with the columns that are exported as
  # NULL: those in @nulled_columns and those that point at a skipped table. Raises before anything is disabled when a
  # moved table cannot be loaded on its own.
  defp plan_export do
    all_tables = Database.list_account_tables()
    tables = all_tables -- @skipped_tables
    foreign_keys = Database.foreign_keys(all_tables)

    nulled =
      for {table, ref, columns} <- foreign_keys, table in tables, ref in @skipped_tables, reduce: @nulled_columns do
        acc ->
          if columns == [] do
            raise "#{table} has a NOT NULL foreign key to the skipped table #{ref}"
          end

          Map.update(acc, table, columns, &Enum.uniq(&1 ++ columns))
      end

    foreign_keys
    |> Enum.filter(fn {table, ref, _columns} -> table in tables and ref in tables end)
    |> then(&order_tables(tables, &1))
    |> Enum.map(&%{name: &1, nulled_columns: Map.get(nulled, &1, [])})
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

  # Each file goes up before the manifest that names it, so an import never
  # sees a manifest without its files. The checksums catch files left over
  # from an earlier export of the same account.
  # sobelow_skip ["Traversal.FileModule"]
  defp upload_export(dir, account, plan, billing) do
    {:ok, {account_columns, tables, suppressions}} = Database.export_tables(dir, account.id, plan)

    checksums =
      Map.new(["accounts" | Enum.map(tables, & &1["name"])], fn table ->
        body = File.read!(Path.join(dir, copy_file(table)))
        :ok = Storage.put!(:outbox, account.id, copy_file(table), body)
        {table, sha256(body)}
      end)

    billing_checksum = if billing, do: upload_billing(account.id, billing)

    manifest = %{
      "account_id" => account.id,
      "name" => account.name,
      "slug" => account.slug,
      "slugs" => Database.list_slugs(account.id),
      "schema_version" => Database.schema_version(),
      "exported_at" => DateTime.to_iso8601(DateTime.utc_now()),
      "account_columns" => account_columns,
      "tables" => tables,
      "checksums" => checksums,
      "billing_checksum" => billing_checksum,
      "email_suppressions" => suppressions
    }

    :ok = Storage.put!(:outbox, account.id, @manifest, Jason.encode!(manifest, pretty: true))
    manifest
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp download_export(dir, manifest) do
    Enum.reduce_while(manifest["checksums"], :ok, fn {table, checksum}, :ok ->
      with {:ok, body} <- Storage.get(:inbox, manifest["account_id"], copy_file(table)),
           ^checksum <- sha256(body) do
        File.write!(Path.join(dir, copy_file(table)), body)
        {:cont, :ok}
      else
        {:error, :not_found} -> {:halt, {:error, {:file_missing, table}}}
        _checksum -> {:halt, {:error, {:checksum_mismatch, table}}}
      end
    end)
  end

  defp download_and_import(dir, manifest) do
    with :ok <- download_export(dir, manifest),
         {:ok, billing} <- download_billing(manifest) do
      Database.import_tables(dir, manifest, billing)
    end
  end

  defp upload_billing(account_id, billing) do
    body = Jason.encode!(billing)
    :ok = Storage.put!(:outbox, account_id, @billing, body)
    sha256(body)
  end

  defp download_billing(%{"billing_checksum" => checksum} = manifest) when is_binary(checksum) do
    case Storage.get(:inbox, manifest["account_id"], @billing) do
      {:ok, body} -> if sha256(body) == checksum, do: {:ok, Jason.decode!(body)}, else: {:error, {:checksum_mismatch, "billing"}}
      {:error, :not_found} -> {:error, {:file_missing, "billing"}}
    end
  end

  defp download_billing(_manifest), do: {:ok, nil}

  @doc "Shows the subscription that `migrate_billing/2` creates. Run it in the destination region."
  defdelegate plan_billing(account_id, opts \\ []), to: Billing, as: :plan

  @doc "Recreates the subscription in the destination region. See `Portal.Ops.RegionTransfer.Billing.migrate/2`."
  defdelegate migrate_billing(account_id, opts \\ []), to: Billing, as: :migrate

  defp copy_file(table), do: "#{table}.copy"

  defp sha256(body), do: :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)

  # sobelow_skip ["Traversal.FileModule"]
  defp with_scratch_dir(fun) do
    dir = Path.join(System.tmp_dir!(), "region-transfer-#{Ecto.UUID.generate()}")
    File.mkdir_p!(dir)

    try do
      fun.(dir)
    after
      File.rm_rf!(dir)
    end
  end

  defp confirm_import(manifest, opts) do
    rows = Enum.map(manifest["tables"], &{&1["name"], &1["rows"]})
    print_summary("Import", manifest, rows)

    if confirm?(opts, "Import #{total_rows(manifest)} rows? [y/N]") do
      case with_scratch_dir(&download_and_import(&1, manifest)) do
        {:ok, imported} ->
          IO.puts("Imported #{imported} rows. The account stays disabled until enable/2 runs.")
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

  defp confirm?(opts, prompt) do
    if Keyword.get(opts, :confirm, true) do
      IO.puts(prompt)
      IO.gets("") |> String.trim() |> String.downcase() == "y"
    else
      true
    end
  end

  # Kahn's algorithm over the foreign keys between the moved tables. A
  # self-reference needs no ordering because COPY checks it at the end of
  # the statement.
  defp order_tables(tables, foreign_keys) do
    deps =
      Map.new(tables, fn table ->
        {table, for({^table, ref, _columns} <- foreign_keys, ref != table, uniq: true, do: ref)}
      end)

    do_order(Enum.sort(tables), deps, [])
  end

  defp do_order([], _deps, ordered), do: Enum.reverse(ordered)

  defp do_order(remaining, deps, ordered) do
    case Enum.filter(remaining, fn table -> Enum.all?(deps[table], &(&1 not in remaining)) end) do
      [] -> raise "cannot order tables, there is a foreign key cycle among #{inspect(remaining)}"
      ready -> do_order(remaining -- ready, deps, Enum.reverse(ready) ++ ordered)
    end
  end

  defmodule Database do
    import Ecto.Query
    alias Portal.Account
    alias Portal.AccountSlug
    alias Portal.Ops.RegionTransfer.Billing
    alias Portal.EmailSuppression
    alias Portal.OutboundEmailDelivery
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

    def list_slugs(account_id) do
      from(s in AccountSlug, where: s.account_id == ^account_id, select: s.slug, order_by: s.slug)
      |> Safe.unscoped()
      |> Safe.all()
    end

    # Any spelling of the slugs already held here, by the account or in the
    # slug history of another one.
    def taken_slugs(slugs) do
      spellings = slugs |> Enum.flat_map(&AccountSlug.spellings/1) |> Enum.uniq()

      current =
        from(a in Account, where: a.slug in ^spellings, select: a.slug)
        |> Safe.unscoped()
        |> Safe.all()

      history =
        from(s in AccountSlug, where: s.slug in ^spellings, select: s.slug)
        |> Safe.unscoped()
        |> Safe.all()

      Enum.uniq(current ++ history)
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

    def put_billing_state(account, state) do
      account
      |> Ecto.Changeset.cast(%{metadata: %{region_transfer: state}}, [])
      |> Ecto.Changeset.cast_embed(:metadata)
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
    # nullable_columns}`.
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

    # One REPEATABLE READ transaction, so every table comes from the same
    # snapshot. The level is set as the connection default because
    # SET TRANSACTION fails inside the test sandbox's transaction.
    def export_tables(dir, account_id, plan) do
      Safe.checkout(Safe.unscoped(), fn ->
        query!("SET default_transaction_isolation = 'repeatable read'", [])

        try do
          Safe.transact(fn -> export_snapshot(dir, account_id, plan) end)
        after
          query!("RESET default_transaction_isolation", [])
        end
      end)
    end

    defp export_snapshot(dir, account_id, plan) do
      account_columns = columns("accounts")
      1 = copy_out("accounts", account_columns, [], "id", account_id, Path.join(dir, "accounts.copy"))

      tables =
        Enum.map(plan, fn %{name: name, nulled_columns: nulled} ->
          columns = columns(name)
          rows = copy_out(name, columns, nulled, "account_id", account_id, Path.join(dir, "#{name}.copy"))
          %{"name" => name, "columns" => columns, "rows" => rows, "nulled_columns" => nulled}
        end)

      {:ok, {account_columns, tables, list_suppressions(account_id)}}
    end

    defp list_suppressions(account_id) do
      actor_emails =
        from(a in Portal.Actor, where: a.account_id == ^account_id and not is_nil(a.email), select: a.email)
        |> Safe.unscoped()
        |> Safe.all()

      recipient_emails =
        from(d in OutboundEmailDelivery, where: d.account_id == ^account_id, distinct: true, select: d.email)
        |> Safe.unscoped()
        |> Safe.all()

      addresses = (actor_emails ++ recipient_emails) |> Enum.map(&EmailSuppression.normalize_email/1) |> Enum.uniq()

      from(s in EmailSuppression, where: s.email in ^addresses, order_by: s.email)
      |> Safe.unscoped()
      |> Safe.all()
      |> Enum.map(&%{"email" => &1.email, "inserted_at" => DateTime.to_iso8601(&1.inserted_at)})
    end

    # sobelow_skip ["Traversal.FileModule"]
    defp copy_out(table, columns, nulled, where_column, account_id, path) do
      {:ok, account_id} = Ecto.UUID.cast(account_id)
      select = Enum.map_join(columns, ", ", &if(&1 in nulled, do: "NULL", else: ident(&1)))

      sql = ~s[COPY (SELECT #{select} FROM #{ident(table)} WHERE #{ident(where_column)} = '#{account_id}') TO STDOUT]

      File.open!(path, [:write, :binary], &copy_to_file(sql, &1))
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

    def import_tables(dir, manifest, billing) do
      Safe.transact(fn ->
        copy_in("accounts", manifest["account_columns"], Path.join(dir, "accounts.copy"))

        Enum.each(manifest["tables"], fn %{"name" => name, "columns" => columns} ->
          copy_in(name, columns, Path.join(dir, "#{name}.copy"))
        end)

        insert_suppressions(manifest["email_suppressions"])

        # The account row carries the source state, which the destination replaces.
        {:ok, _account} =
          manifest["account_id"] |> fetch_account!() |> put_billing_state(Billing.transfer_state(billing, "pending"))

        verify_counts(manifest)
      end)
    end

    defp insert_suppressions([]), do: :ok

    defp insert_suppressions(suppressions) do
      rows =
        Enum.map(suppressions, fn %{"email" => email, "inserted_at" => inserted_at} ->
          {:ok, inserted_at, 0} = DateTime.from_iso8601(inserted_at)
          %{email: email, inserted_at: inserted_at}
        end)

      Safe.unscoped() |> Safe.insert_all(EmailSuppression, rows, on_conflict: :nothing)
      :ok
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

    defp idents(columns), do: Enum.map_join(columns, ", ", &ident/1)

    defp ident(name), do: ~s["#{String.replace(name, ~s["], ~s[""])}"]

    defp query!(sql, params) do
      {:ok, result} = Safe.unscoped() |> Safe.query(sql, params)
      result
    end
  end
end
