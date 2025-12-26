defmodule Portal.Workers.CheckAccountLimits do
  @moduledoc """
  Oban worker that checks account limits and updates warning messages.
  Runs every 30 minutes.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [period: :infinity, states: [:available, :scheduled, :executing, :retryable]]

  alias Portal.Billing
  alias __MODULE__.DB

  @batch_size 100

  @impl Oban.Worker
  def perform(_job) do
    process_accounts_in_batches(nil)
  end

  defp process_accounts_in_batches(cursor) do
    case DB.fetch_active_accounts_batch(cursor, @batch_size) do
      [] ->
        :ok

      accounts ->
        Enum.each(accounts, &check_account_limits/1)
        last_account = List.last(accounts)
        process_accounts_in_batches(last_account.id)
    end
  end

  defp check_account_limits(account) do
    if Billing.account_provisioned?(account) do
      []
      |> check_users_limit(account)
      |> check_seats_limit(account)
      |> check_service_accounts_limit(account)
      |> check_sites_limit(account)
      |> check_admin_limit(account)
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

  defp check_users_limit(limits_exceeded, account) do
    users_count = DB.count_users_for_account(account)

    if Billing.users_limit_exceeded?(account, users_count) do
      limits_exceeded ++ ["users"]
    else
      limits_exceeded
    end
  end

  defp check_seats_limit(limits_exceeded, account) do
    active_users_count = DB.count_1m_active_users_for_account(account)

    if Billing.seats_limit_exceeded?(account, active_users_count) do
      limits_exceeded ++ ["monthly active users"]
    else
      limits_exceeded
    end
  end

  defp check_service_accounts_limit(limits_exceeded, account) do
    service_accounts_count = DB.count_service_accounts_for_account(account)

    if Billing.service_accounts_limit_exceeded?(account, service_accounts_count) do
      limits_exceeded ++ ["service accounts"]
    else
      limits_exceeded
    end
  end

  defp check_sites_limit(limits_exceeded, account) do
    sites_count = DB.count_sites_for_account(account)

    if Billing.sites_limit_exceeded?(account, sites_count) do
      limits_exceeded ++ ["sites"]
    else
      limits_exceeded
    end
  end

  defp check_admin_limit(limits_exceeded, account) do
    account_admins_count = DB.count_account_admin_users_for_account(account)

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
    |> DB.update()
  end

  defmodule DB do
    import Ecto.Query
    alias Portal.Safe
    alias Portal.Account
    alias Portal.Actor
    alias Portal.Client

    def fetch_active_accounts_batch(cursor, limit) do
      from(a in Account,
        where: is_nil(a.disabled_at),
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

    def count_users_for_account(%Account{} = account) do
      from(a in Actor,
        where: a.account_id == ^account.id,
        where: is_nil(a.disabled_at),
        where: a.type in [:account_admin_user, :account_user]
      )
      |> Safe.unscoped()
      |> Safe.aggregate(:count)
    end

    def count_service_accounts_for_account(%Account{} = account) do
      from(a in Actor,
        where: a.account_id == ^account.id,
        where: is_nil(a.disabled_at),
        where: a.type == :service_account
      )
      |> Safe.unscoped()
      |> Safe.aggregate(:count)
    end

    def count_account_admin_users_for_account(%Account{} = account) do
      from(a in Actor,
        where: a.account_id == ^account.id,
        where: is_nil(a.disabled_at),
        where: a.type == :account_admin_user
      )
      |> Safe.unscoped()
      |> Safe.aggregate(:count)
    end

    def count_1m_active_users_for_account(%Account{} = account) do
      from(c in Client, as: :clients)
      |> where([clients: c], c.account_id == ^account.id)
      |> where([clients: c], c.last_seen_at > ago(1, "month"))
      |> join(:inner, [clients: c], a in Actor,
        on: c.actor_id == a.id and c.account_id == a.account_id,
        as: :actor
      )
      |> where([actor: a], is_nil(a.disabled_at))
      |> where([actor: a], a.type in [:account_user, :account_admin_user])
      |> select([clients: c], c.actor_id)
      |> distinct(true)
      |> Safe.unscoped()
      |> Safe.aggregate(:count)
    end

    def count_sites_for_account(account) do
      from(g in Portal.Site,
        where: g.account_id == ^account.id,
        where: g.managed_by == :account
      )
      |> Safe.unscoped()
      |> Safe.aggregate(:count)
    end
  end
end
