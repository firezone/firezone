defmodule API.AccountJSON do
  alias Domain.{Accounts, Actors, Clients, Gateways}

  @doc """
  Render a single Account
  """
  def show(%{account: account}) do
    %{data: data(account)}
  end

  defp data(%Accounts.Account{} = account) do
    %{
      id: account.id,
      slug: account.slug,
      name: account.name,
      legal_name: account.legal_name,
      limits: build_limits(account)
    }
  end

  defp build_limits(account) do
    # Get current usage counts
    users_count = Actors.count_users_for_account(account)
    monthly_active_users_count = Clients.count_1m_active_users_for_account(account)
    service_accounts_count = Actors.count_service_accounts_for_account(account)
    admin_users_count = Actors.count_account_admin_users_for_account(account)
    gateway_groups_count = Gateways.count_groups_for_account(account)

    limits = %{}

    # Only include limits that are set on the account
    limits =
      if account.limits.users_count do
        Map.put(limits, :users, %{
          used: users_count,
          available: max(0, account.limits.users_count - users_count),
          total: account.limits.users_count
        })
      else
        limits
      end

    limits =
      if account.limits.monthly_active_users_count do
        Map.put(limits, :monthly_active_users, %{
          used: monthly_active_users_count,
          available:
            max(0, account.limits.monthly_active_users_count - monthly_active_users_count),
          total: account.limits.monthly_active_users_count
        })
      else
        limits
      end

    limits =
      if account.limits.service_accounts_count do
        Map.put(limits, :service_accounts, %{
          used: service_accounts_count,
          available: max(0, account.limits.service_accounts_count - service_accounts_count),
          total: account.limits.service_accounts_count
        })
      else
        limits
      end

    limits =
      if account.limits.account_admin_users_count do
        Map.put(limits, :account_admin_users, %{
          used: admin_users_count,
          available: max(0, account.limits.account_admin_users_count - admin_users_count),
          total: account.limits.account_admin_users_count
        })
      else
        limits
      end

    limits =
      if account.limits.gateway_groups_count do
        Map.put(limits, :gateway_groups, %{
          used: gateway_groups_count,
          available: max(0, account.limits.gateway_groups_count - gateway_groups_count),
          total: account.limits.gateway_groups_count
        })
      else
        limits
      end

    limits
  end
end
