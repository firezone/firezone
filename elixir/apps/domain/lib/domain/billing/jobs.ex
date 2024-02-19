defmodule Domain.Billing.Jobs do
  use Domain.Jobs.Recurrent, otp_app: :domain
  alias Domain.{Accounts, Billing, Actors, Clients, Gateways}

  every minutes(30), :check_account_limits do
    {:ok, accounts} = Accounts.list_active_accounts()

    Enum.each(accounts, fn account ->
      []
      |> check_seats_limit(account)
      |> check_service_accounts_limit(account)
      |> check_sites_limit(account)
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
          warning = "You have exceeded the following limits: #{Enum.join(limits_exceeded, ", ")}."

          {:ok, _account} =
            Accounts.update_account(account, %{
              warning: warning,
              warning_delivery_attempts: 0,
              warning_last_sent_at: DateTime.utc_now()
            })

          :ok
      end
    end)
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

  defp check_sites_limit(limits_exceeded, account) do
    sites_count = Gateways.count_groups_for_account(account)

    if Billing.sites_limit_exceeded?(account, sites_count) do
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
