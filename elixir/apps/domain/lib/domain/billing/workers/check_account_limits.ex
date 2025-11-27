defmodule Domain.Billing.Workers.CheckAccountLimits do
  @moduledoc """
  Oban worker that checks account limits and updates warning messages.
  Runs every 5 minutes.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [period: 300]

  alias Domain.{Accounts, Billing, Gateways}
  alias __MODULE__.DB

  @impl Oban.Worker
  def perform(_job) do
    DB.all_active_accounts()
    |> Enum.each(fn account ->
      # TODO: Slow DB queries
      # These can be slow if an index-only scan is not possible.
      # Consider using a trigger function and counter fields to maintain an accurate
      # count of account limits.
      if Billing.enabled?() and Billing.account_provisioned?(account) do
        []
        |> check_users_limit(account)
        |> check_seats_limit(account)
        |> check_service_accounts_limit(account)
        |> check_gateway_groups_limit(account)
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
    end)
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

  defp check_gateway_groups_limit(limits_exceeded, account) do
    gateway_groups_count = DB.count_groups_for_account(account)

    if Billing.gateway_groups_limit_exceeded?(account, gateway_groups_count) do
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
    alias Domain.{Safe, Repo}
    alias Domain.Accounts.Account
    alias Domain.Actors.Actor
    alias Domain.Client

    def all_active_accounts do
      from(a in Account, where: is_nil(a.disabled_at))
      |> Safe.unscoped()
      |> Safe.all()
    end

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
      |> join(:inner, [clients: c], a in Actor, on: c.actor_id == a.id, as: :actor)
      |> where([actor: a], is_nil(a.disabled_at))
      |> where([actor: a], a.type in [:account_user, :account_admin_user])
      |> select([clients: c], c.actor_id)
      |> distinct(true)
      |> Repo.aggregate(:count)
    end
    
    def count_groups_for_account(account) do
      from(g in Domain.Gateways.Group,
        where: g.account_id == ^account.id,
        where: g.managed_by == :account
      )
      |> Safe.unscoped()
      |> Safe.aggregate(:count)
    end
  end
end
