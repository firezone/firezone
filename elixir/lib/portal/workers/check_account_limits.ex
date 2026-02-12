defmodule Portal.Workers.CheckAccountLimits do
  @moduledoc """
  Oban worker that checks account limits and updates limit exceeded flags.
  Runs every 30 minutes.

  Optimized to use batched GROUP BY queries instead of per-account queries
  to minimize database load.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [period: :infinity, states: [:available, :scheduled, :executing, :retryable]]

  alias Portal.Account
  alias Portal.Billing
  alias Portal.Mailer
  alias Portal.Mailer.Notifications
  alias __MODULE__.Database
  require Logger

  # Send email reminder every 3 days
  @email_reminder_interval_days 3

  @batch_size 100

  @impl Oban.Worker
  def perform(_job) do
    # Pre-compute all counts for all active accounts in 5 batched queries
    # instead of 5 queries per account (N+1 -> 5 total queries)
    counts = Database.fetch_all_counts_for_active_accounts()
    process_accounts_in_batches(nil, counts)
  end

  defp process_accounts_in_batches(cursor, counts) do
    case Database.fetch_active_accounts_batch(cursor, @batch_size) do
      [] ->
        :ok

      accounts ->
        Enum.each(accounts, &check_account_limits(&1, counts))
        last_account = List.last(accounts)
        process_accounts_in_batches(last_account.id, counts)
    end
  end

  defp check_account_limits(account, counts) do
    if Billing.account_provisioned?(account) do
      account_counts = Map.get(counts, account.id, %{})
      flags = limit_flags(account, account_counts)

      if any_exceeded?(flags) do
        handle_exceeded_limits(account, flags, account_counts)
      else
        update_account_limits(account, cleared_flags())
      end
    end

    :ok
  end

  defp limit_flags(account, account_counts) do
    users = Map.get(account_counts, :users, 0)
    active_users = Map.get(account_counts, :active_users, 0)
    service_accounts = Map.get(account_counts, :service_accounts, 0)
    sites = Map.get(account_counts, :sites, 0)
    admins = Map.get(account_counts, :admins, 0)

    %{
      users_limit_exceeded: Billing.users_limit_exceeded?(account, users),
      seats_limit_exceeded: Billing.seats_limit_exceeded?(account, active_users),
      service_accounts_limit_exceeded:
        Billing.service_accounts_limit_exceeded?(account, service_accounts),
      sites_limit_exceeded: Billing.sites_limit_exceeded?(account, sites),
      admins_limit_exceeded: Billing.admins_limit_exceeded?(account, admins)
    }
  end

  defp any_exceeded?(flags), do: Enum.any?(flags, fn {_k, v} -> v end)

  defp handle_exceeded_limits(account, flags, counts) do
    # Log when seats limit transitions from not-exceeded to exceeded.
    # Unlike other limits, seats is a "soft" limit that doesn't block sign-ins,
    # so we log here to have visibility into when accounts exceed it.
    if not account.seats_limit_exceeded and flags.seats_limit_exceeded do
      Logger.warning("Account seats limit exceeded",
        account_id: account.id,
        account_slug: account.slug,
        count: counts[:active_users],
        limit: account.limits && account.limits.monthly_active_users_count
      )
    end

    send_email? = should_send_email?(account)
    flags = maybe_put_sent_at(flags, send_email?)

    {:ok, updated_account} = update_account_limits(account, flags)

    if send_email? do
      warning = Billing.build_limits_exceeded_message(updated_account, counts)
      send_limit_exceeded_emails(updated_account, warning)
    end
  end

  defp maybe_put_sent_at(flags, true),
    do: Map.put(flags, :warning_last_sent_at, DateTime.utc_now())

  defp maybe_put_sent_at(flags, false), do: flags

  defp cleared_flags do
    [
      :users_limit_exceeded,
      :seats_limit_exceeded,
      :service_accounts_limit_exceeded,
      :sites_limit_exceeded,
      :admins_limit_exceeded
    ]
    |> Map.new(fn k -> {k, false} end)
    |> Map.put(:warning_last_sent_at, nil)
  end

  defp should_send_email?(%{warning_last_sent_at: nil}), do: true

  defp should_send_email?(%{warning_last_sent_at: last_sent_at}) do
    days_since_last_email = DateTime.diff(DateTime.utc_now(), last_sent_at, :day)
    days_since_last_email >= @email_reminder_interval_days
  end

  defp send_limit_exceeded_emails(account, warning) do
    admins = Database.get_account_admin_actors(account.id)

    case admins do
      [] ->
        Logger.warning("No admin actors found for account",
          account_id: account.id
        )

      admins ->
        Enum.each(admins, fn admin ->
          send_limit_exceeded_email(account, admin, warning)
        end)
    end
  end

  defp send_limit_exceeded_email(account, admin, warning) do
    Logger.info("Sending limits exceeded email",
      to: admin.email,
      account_id: account.id
    )

    Notifications.limits_exceeded_email(account, warning, admin.email)
    |> Mailer.deliver()
    |> case do
      {:ok, _result} ->
        Logger.info("Limits exceeded email sent successfully",
          to: admin.email,
          account_id: account.id
        )

      {:error, reason} ->
        Logger.error("Failed to send limits exceeded email",
          to: admin.email,
          reason: inspect(reason),
          account_id: account.id
        )
    end
  end

  defp update_account_limits(account, attrs) do
    import Ecto.Changeset

    fields = [
      :users_limit_exceeded,
      :seats_limit_exceeded,
      :service_accounts_limit_exceeded,
      :sites_limit_exceeded,
      :admins_limit_exceeded,
      :warning_last_sent_at
    ]

    account
    |> cast(attrs, fields)
    |> Database.update()
  end

  defmodule Database do
    import Ecto.Query
    alias Portal.Safe
    alias Portal.Account
    alias Portal.Actor
    alias Portal.Client

    @doc """
    Fetches all counts for all active accounts in batched GROUP BY queries.
    Returns a map of account_id -> %{users: n, active_users: n, service_accounts: n, sites: n, admins: n}
    """
    def fetch_all_counts_for_active_accounts do
      # Run all count queries in parallel using Task.async_stream
      # Each query returns a map of account_id -> count
      tasks = [
        {:users, fn -> count_users_by_account() end},
        {:active_users, fn -> count_1m_active_users_by_account() end},
        {:service_accounts, fn -> count_service_accounts_by_account() end},
        {:sites, fn -> count_sites_by_account() end},
        {:admins, fn -> count_admins_by_account() end}
      ]

      results =
        tasks
        |> Task.async_stream(fn {key, func} -> {key, func.()} end, timeout: :infinity)
        |> Enum.map(fn {:ok, result} -> result end)
        |> Map.new()

      # Merge all count maps into a single map of account_id -> %{users: n, ...}
      merge_count_maps(results)
    end

    defp merge_count_maps(results) do
      # Get all unique account_ids from all result maps
      all_account_ids =
        results
        |> Map.values()
        |> Enum.flat_map(&Map.keys/1)
        |> Enum.uniq()

      # Build the merged map
      Map.new(all_account_ids, fn account_id ->
        counts = %{
          users: get_in(results, [:users, account_id]) || 0,
          active_users: get_in(results, [:active_users, account_id]) || 0,
          service_accounts: get_in(results, [:service_accounts, account_id]) || 0,
          sites: get_in(results, [:sites, account_id]) || 0,
          admins: get_in(results, [:admins, account_id]) || 0
        }

        {account_id, counts}
      end)
    end

    def fetch_active_accounts_batch(cursor, limit) do
      from(a in Account,
        where: is_nil(a.disabled_at),
        order_by: [asc: a.id],
        limit: ^limit
      )
      |> maybe_after_cursor(cursor)
      |> Safe.unscoped(:replica)
      |> Safe.all()
    end

    defp maybe_after_cursor(query, nil), do: query
    defp maybe_after_cursor(query, cursor), do: where(query, [a], a.id > ^cursor)

    def update(changeset) do
      changeset
      |> Safe.unscoped()
      |> Safe.update()
    end

    # Batched count queries - one query for all active accounts using GROUP BY

    defp count_users_by_account do
      from(a in Actor,
        join: acc in Account,
        on: acc.id == a.account_id and is_nil(acc.disabled_at),
        where: is_nil(a.disabled_at),
        where: a.type in [:account_admin_user, :account_user],
        group_by: a.account_id,
        select: {a.account_id, count(a.id)}
      )
      |> Safe.unscoped(:replica)
      |> Safe.all()
      |> Map.new()
    end

    defp count_service_accounts_by_account do
      from(a in Actor,
        join: acc in Account,
        on: acc.id == a.account_id and is_nil(acc.disabled_at),
        where: is_nil(a.disabled_at),
        where: a.type == :service_account,
        group_by: a.account_id,
        select: {a.account_id, count(a.id)}
      )
      |> Safe.unscoped(:replica)
      |> Safe.all()
      |> Map.new()
    end

    defp count_admins_by_account do
      from(a in Actor,
        join: acc in Account,
        on: acc.id == a.account_id and is_nil(acc.disabled_at),
        where: is_nil(a.disabled_at),
        where: a.type == :account_admin_user,
        group_by: a.account_id,
        select: {a.account_id, count(a.id)}
      )
      |> Safe.unscoped(:replica)
      |> Safe.all()
      |> Map.new()
    end

    defp count_1m_active_users_by_account do
      # Use a subquery to get distinct actor_ids per account, then count
      subquery =
        from(c in Client, as: :clients)
        |> join(:inner, [clients: c], acc in Account,
          on: acc.id == c.account_id and is_nil(acc.disabled_at),
          as: :account
        )
        |> join(:inner, [clients: c], s in Portal.ClientSession,
          on: s.client_id == c.id and s.account_id == c.account_id,
          as: :session
        )
        |> where([session: s], s.inserted_at > ago(1, "month"))
        |> join(:inner, [clients: c], a in Actor,
          on: c.actor_id == a.id and c.account_id == a.account_id,
          as: :actor
        )
        |> where([actor: a], is_nil(a.disabled_at))
        |> where([actor: a], a.type in [:account_user, :account_admin_user])
        |> select([clients: c], %{account_id: c.account_id, actor_id: c.actor_id})
        |> distinct(true)

      from(s in subquery(subquery),
        group_by: s.account_id,
        select: {s.account_id, count(s.actor_id)}
      )
      |> Safe.unscoped(:replica)
      |> Safe.all()
      |> Map.new()
    end

    defp count_sites_by_account do
      from(g in Portal.Site,
        join: acc in Account,
        on: acc.id == g.account_id and is_nil(acc.disabled_at),
        where: g.managed_by == :account,
        group_by: g.account_id,
        select: {g.account_id, count(g.id)}
      )
      |> Safe.unscoped(:replica)
      |> Safe.all()
      |> Map.new()
    end

    def get_account_admin_actors(account_id) do
      from(a in Actor,
        where: a.account_id == ^account_id,
        where: a.type == :account_admin_user,
        where: is_nil(a.disabled_at)
      )
      |> Safe.unscoped(:replica)
      |> Safe.all()
    end
  end
end
