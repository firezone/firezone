defmodule Portal.Workers.CheckAccountLimits do
  @moduledoc """
  Oban worker that checks account limits and updates limit exceeded flags.
  Runs every 30 minutes.

  Optimized to use batched GROUP BY queries per account batch instead of
  per-account queries to minimize database load while keeping each query bounded.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [period: :infinity, states: :incomplete]

  import Ecto.Changeset, only: [cast: 3]

  alias Portal.Account
  alias Portal.Billing
  alias Portal.Mailer
  alias Portal.Mailer.InternalEmail
  alias Portal.Mailer.Notifications
  alias __MODULE__.Database
  require Logger

  # Send email reminder every 3 days
  @email_reminder_interval_days 3

  # Business blocks new users at its seat limit, so its admins are warned before
  # and at the limit, once per level until plenty of seats are free again.
  @seats_warning_rank %{nil => 0, :approaching => 1, :at_limit => 2}

  # Enterprise is not blocked, so going over is reported to Firezone instead,
  # again every 30 days while the account stays over.
  @seats_overage_report_interval_days 30

  @batch_size 100

  @impl Oban.Worker
  def perform(_job) do
    process_accounts_in_batches(nil)
  end

  defp process_accounts_in_batches(cursor) do
    case Database.fetch_enabled_accounts_batch(cursor, @batch_size) do
      [] ->
        :ok

      accounts ->
        counts = Database.fetch_counts_for_accounts(accounts)

        Enum.each(accounts, &check_account_limits(&1, counts))
        last_account = List.last(accounts)
        process_accounts_in_batches(last_account.id)
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

      maybe_send_seats_warning_email(account, account_counts)
    end

    :ok
  end

  defp maybe_send_seats_warning_email(account, account_counts) do
    active_users = Map.get(account_counts, :active_users, 0)

    case {Billing.plan_type(account), Billing.seats_warning_level(account, active_users)} do
      {_plan, :clear} ->
        clear_seats_warning(account)

      {:business, level} when level in [:approaching, :at_limit] ->
        if @seats_warning_rank[level] > @seats_warning_rank[account.seats_warning_level] do
          send_seats_warning_email(account, level, active_users)
        end

      {:enterprise, :over} ->
        if seats_overage_report_due?(account) and InternalEmail.enabled?() do
          send_seats_overage_report(account, active_users)
        end

      _other ->
        :ok
    end
  end

  defp seats_overage_report_due?(%{seats_warning_level: :over} = account) do
    DateTime.diff(DateTime.utc_now(), account.seats_warning_last_sent_at, :day) >=
      @seats_overage_report_interval_days
  end

  defp seats_overage_report_due?(_account), do: true

  defp send_seats_overage_report(account, active_users) do
    account
    |> InternalEmail.seats_overage_email(active_users)
    |> Mailer.enqueue()
    |> case do
      {:ok, _result} ->
        put_seats_warning(account, DateTime.utc_now(), :over)

      {:error, reason} ->
        Logger.error("Failed to enqueue seats overage report",
          reason: inspect(reason),
          account_id: account.id
        )
    end
  end

  defp clear_seats_warning(%{seats_warning_last_sent_at: nil, seats_warning_level: nil}), do: :ok

  defp clear_seats_warning(account), do: put_seats_warning(account, nil, nil)

  defp put_seats_warning(account, sent_at, level) do
    account
    |> cast(%{seats_warning_last_sent_at: sent_at, seats_warning_level: level}, [
      :seats_warning_last_sent_at,
      :seats_warning_level
    ])
    |> Database.update()
  end

  defp send_seats_warning_email(account, level, active_users) do
    case Database.get_seats_warning_recipients(account.id) do
      [] ->
        Logger.info("No admin actors receive seats warnings for account", account_id: account.id)

      admins ->
        sent_count =
          Enum.count(admins, &(enqueue_seats_warning_email(account, level, active_users, &1) == :ok))

        if sent_count > 0 do
          Logger.info("Seats warning email enqueued",
            level: level,
            recipient_count: sent_count,
            account_id: account.id
          )

          put_seats_warning(account, DateTime.utc_now(), level)
        end
    end
  end

  defp enqueue_seats_warning_email(account, level, active_users, admin) do
    Notifications.seats_warning_email(account, level, active_users, admin)
    |> Mailer.enqueue()
    |> case do
      {:ok, _result} ->
        :ok

      {:error, reason} ->
        Logger.error("Failed to enqueue seats warning email",
          level: level,
          actor_id: admin.id,
          reason: inspect(reason),
          account_id: account.id
        )

        :error
    end
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

    emailed_flags = limits_exceeded_email_flags(account, flags)
    send_email? = any_exceeded?(emailed_flags) and should_send_email?(account)
    flags = maybe_put_sent_at(flags, send_email?)

    {:ok, updated_account} = update_account_limits(account, flags)

    if send_email? do
      warning = Billing.build_limits_exceeded_message(struct(updated_account, emailed_flags), counts)
      send_limit_exceeded_emails(updated_account, warning)
    end
  end

  # Enterprise seats are not enforced and going over them is reported to
  # Firezone instead, so they are left out of this email to the admins.
  defp limits_exceeded_email_flags(account, flags) do
    if Billing.plan_type(account) == :enterprise do
      %{flags | seats_limit_exceeded: false}
    else
      flags
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

  # Dormancy is checked last so the reminder clock only starts once there is
  # somebody to remind.
  defp should_send_email?(account) do
    due_for_email?(account) and not dormant?(account)
  end

  defp dormant?(account) do
    not Billing.paid_plan?(account) and not Database.account_active?(account.id)
  end

  defp due_for_email?(%{warning_last_sent_at: nil}), do: true

  defp due_for_email?(%{warning_last_sent_at: last_sent_at}) do
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
        send_limit_exceeded_email(account, admins, warning)
    end
  end

  defp send_limit_exceeded_email(account, admins, warning) do
    recipient_emails = Enum.map(admins, & &1.email)

    Logger.info("Sending limits exceeded email",
      recipient_count: length(recipient_emails),
      account_id: account.id
    )

    Notifications.limits_exceeded_email(account, warning, recipient_emails)
    |> Mailer.enqueue()
    |> case do
      {:ok, _result} ->
        Logger.info("Limits exceeded email enqueued successfully",
          recipient_count: length(recipient_emails),
          account_id: account.id
        )

      {:error, reason} ->
        Logger.error("Failed to enqueue limits exceeded email",
          recipient_count: length(recipient_emails),
          reason: inspect(reason),
          account_id: account.id
        )
    end
  end

  defp update_account_limits(account, attrs) do
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
    alias Portal.Actor

    @doc """
    Fetches counts for the given accounts in batched GROUP BY queries.
    Returns a map of account_id -> %{users: n, active_users: n, service_accounts: n, sites: n, admins: n}
    """
    def fetch_counts_for_accounts([]), do: %{}

    def fetch_counts_for_accounts(accounts) do
      account_ids = Enum.map(accounts, & &1.id)

      results = %{
        users: count_users_by_account(account_ids),
        active_users: Billing.count_monthly_active_users_by_account(accounts),
        service_accounts: count_service_accounts_by_account(account_ids),
        sites: count_sites_by_account(account_ids),
        admins: count_admins_by_account(account_ids)
      }

      merge_count_maps(account_ids, results)
    end

    defp merge_count_maps(account_ids, results) do
      Map.new(account_ids, fn account_id ->
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

    def fetch_enabled_accounts_batch(cursor, limit) do
      from(a in Account,
        where: a.is_disabled == false,
        order_by: [asc: a.id],
        limit: ^limit
      )
      |> maybe_after_cursor(cursor)
      |> Safe.unscoped()
      |> Safe.all()
    end

    defp maybe_after_cursor(query, nil), do: query
    defp maybe_after_cursor(query, cursor), do: where(query, [a], a.id > ^cursor)

    def update(changeset) do
      changeset
      |> Safe.unscoped()
      |> Safe.update()
    end

    # Batched count queries - one query per count type for the current account batch
    defp count_users_by_account(account_ids) do
      from(a in Actor,
        where: a.account_id in ^account_ids,
        where: a.is_disabled == false,
        where: a.type in [:account_admin_user, :account_user],
        group_by: a.account_id,
        select: {a.account_id, count(a.id)}
      )
      |> Safe.unscoped()
      |> Safe.all()
      |> Map.new()
    end

    defp count_service_accounts_by_account(account_ids) do
      from(a in Actor,
        where: a.account_id in ^account_ids,
        where: a.is_disabled == false,
        where: a.type == :service_account,
        group_by: a.account_id,
        select: {a.account_id, count(a.id)}
      )
      |> Safe.unscoped()
      |> Safe.all()
      |> Map.new()
    end

    defp count_admins_by_account(account_ids) do
      from(a in Actor,
        where: a.account_id in ^account_ids,
        where: a.is_disabled == false,
        where: a.type == :account_admin_user,
        group_by: a.account_id,
        select: {a.account_id, count(a.id)}
      )
      |> Safe.unscoped()
      |> Safe.all()
      |> Map.new()
    end

    defp count_sites_by_account(account_ids) do
      from(g in Portal.Site,
        where: g.account_id in ^account_ids,
        where: g.managed_by == :account,
        group_by: g.account_id,
        select: {g.account_id, count(g.id)}
      )
      |> Safe.unscoped()
      |> Safe.all()
      |> Map.new()
    end

    def get_account_admin_actors(account_id) do
      from(a in Actor,
        where: a.account_id == ^account_id,
        where: a.type == :account_admin_user,
        where: a.is_disabled == false
      )
      |> Safe.unscoped()
      |> Safe.all()
    end

    def get_seats_warning_recipients(account_id) do
      from(a in Actor,
        where: a.account_id == ^account_id,
        where: a.type == :account_admin_user,
        where: a.is_disabled == false,
        where:
          fragment(
            "COALESCE(NULLIF(?->'notifications'->'seat_limit_warnings', 'null') @> '[\"email\"]', true)",
            a.preferences
          )
      )
      |> Safe.unscoped()
      |> Safe.all()
    end

    def account_active?(account_id) do
      from(sl in Portal.SessionLog, where: sl.account_id == ^account_id)
      |> Safe.unscoped()
      |> Safe.exists?()
    end
  end
end
