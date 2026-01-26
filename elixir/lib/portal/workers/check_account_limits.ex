defmodule Portal.Workers.CheckAccountLimits do
  @moduledoc """
  Oban worker that checks account limits and updates warning messages.
  Runs every 30 minutes.

  Optimized to use batched GROUP BY queries instead of per-account queries
  to minimize database load.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [period: :infinity, states: [:available, :scheduled, :executing, :retryable]]

  alias Portal.Billing
  alias __MODULE__.Database

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

      []
      |> check_users_limit(account, account_counts)
      |> check_seats_limit(account, account_counts)
      |> check_service_accounts_limit(account, account_counts)
      |> check_sites_limit(account, account_counts)
      |> check_admin_limit(account, account_counts)
      |> case do
        [] ->
          {:ok, _account} =
            update_account_warning(account, %{
              warning: nil,
              warning_delivery_attempts: 0,
              warning_last_sent_at: nil
            })

          :ok

        limits_exceeded ->
          warning =
            "You have exceeded the following limits: #{Enum.join(limits_exceeded, ", ")}"

          {:ok, _account} =
            update_account_warning(account, %{
              warning: warning,
              warning_delivery_attempts: 0,
              warning_last_sent_at: DateTime.utc_now()
            })

          :ok
      end
    else
      :ok
    end
  end

  defp check_users_limit(limits_exceeded, account, counts) do
    users_count = Map.get(counts, :users, 0)

    if Billing.users_limit_exceeded?(account, users_count) do
      limits_exceeded ++ ["users"]
    else
      limits_exceeded
    end
  end

  defp check_seats_limit(limits_exceeded, account, counts) do
    active_users_count = Map.get(counts, :active_users, 0)

    if Billing.seats_limit_exceeded?(account, active_users_count) do
      limits_exceeded ++ ["monthly active users"]
    else
      limits_exceeded
    end
  end

  defp check_service_accounts_limit(limits_exceeded, account, counts) do
    service_accounts_count = Map.get(counts, :service_accounts, 0)

    if Billing.service_accounts_limit_exceeded?(account, service_accounts_count) do
      limits_exceeded ++ ["service accounts"]
    else
      limits_exceeded
    end
  end

  defp check_sites_limit(limits_exceeded, account, counts) do
    sites_count = Map.get(counts, :sites, 0)

    if Billing.sites_limit_exceeded?(account, sites_count) do
      limits_exceeded ++ ["sites"]
    else
      limits_exceeded
    end
  end

  defp check_admin_limit(limits_exceeded, account, counts) do
    account_admins_count = Map.get(counts, :admins, 0)

    if Billing.admins_limit_exceeded?(account, account_admins_count) do
      limits_exceeded ++ ["account admins"]
    else
      limits_exceeded
    end
  end

  defp update_account_warning(account, attrs) do
    import Ecto.Changeset

    account
    |> cast(attrs, [:warning, :warning_delivery_attempts, :warning_last_sent_at])
    |> Database.update()
  end

  defmodule Database do
    import Ecto.Query
    alias Portal.Repo
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
      # credo:disable-for-next-line Credo.Check.Warning.RepoMissingSubject
      |> Repo.all()
    end

    defp maybe_after_cursor(query, nil), do: query
    defp maybe_after_cursor(query, cursor), do: where(query, [a], a.id > ^cursor)

    def update(changeset) do
      # credo:disable-for-next-line Credo.Check.Warning.RepoMissingSubject
      Repo.update(changeset)
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
      # credo:disable-for-next-line Credo.Check.Warning.RepoMissingSubject
      |> Repo.all()
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
      # credo:disable-for-next-line Credo.Check.Warning.RepoMissingSubject
      |> Repo.all()
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
      # credo:disable-for-next-line Credo.Check.Warning.RepoMissingSubject
      |> Repo.all()
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
        |> where([clients: c], c.last_seen_at > ago(1, "month"))
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
      # credo:disable-for-next-line Credo.Check.Warning.RepoMissingSubject
      |> Repo.all()
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
      # credo:disable-for-next-line Credo.Check.Warning.RepoMissingSubject
      |> Repo.all()
      |> Map.new()
    end
  end
end
