defmodule Domain.Billing.Jobs.CheckAccountLimits do
  use Domain.Jobs.Job,
    otp_app: :domain,
    every: :timer.minutes(5),
    executor: Domain.Jobs.Executors.GloballyUnique

  alias Domain.{Accounts, Billing, Actors, Clients, Gateways}

  @impl true
  def execute(_config) do
    Accounts.all_active_accounts!()
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
              Accounts.update_account(account, %{
                warning: nil,
                warning_delivery_attempts: 0,
                warning_last_sent_at: nil
              })

            :ok

          limits_exceeded ->
            warning =
              "You have exceeded the following limits: #{Enum.join(limits_exceeded, ", ")}"

            {:ok, _account} =
              Accounts.update_account(account, %{
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
    users_count = Actors.count_users_for_account(account)

    if Billing.users_limit_exceeded?(account, users_count) do
      limits_exceeded ++ ["users"]
    else
      limits_exceeded
    end
  end

  defp check_seats_limit(limits_exceeded, account) do
    active_users_count = Clients.count_1m_active_users_for_account(account)

    if Billing.seats_limit_exceeded?(account, active_users_count) do
      limits_exceeded ++ ["monthly active users"]
    else
      limits_exceeded
    end
  end

  defp check_service_accounts_limit(limits_exceeded, account) do
    service_accounts_count = Actors.count_service_accounts_for_account(account)

    if Billing.service_accounts_limit_exceeded?(account, service_accounts_count) do
      limits_exceeded ++ ["service accounts"]
    else
      limits_exceeded
    end
  end

  defp check_gateway_groups_limit(limits_exceeded, account) do
    gateway_groups_count = Gateways.count_groups_for_account(account)

    if Billing.gateway_groups_limit_exceeded?(account, gateway_groups_count) do
      limits_exceeded ++ ["sites"]
    else
      limits_exceeded
    end
  end

  defp check_admin_limit(limits_exceeded, account) do
    account_admins_count = Actors.count_account_admin_users_for_account(account)

    if Billing.admins_limit_exceeded?(account, account_admins_count) do
      limits_exceeded ++ ["account admins"]
    else
      limits_exceeded
    end
  end
end
