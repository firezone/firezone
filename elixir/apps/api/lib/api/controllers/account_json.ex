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

    %{}
    |> put_limit(:users, account.limits.users_count, users_count)
    |> put_limit(
      :monthly_active_users,
      account.limits.monthly_active_users_count,
      monthly_active_users_count
    )
    |> put_limit(:service_accounts, account.limits.service_accounts_count, service_accounts_count)
    |> put_limit(
      :account_admin_users,
      account.limits.account_admin_users_count,
      admin_users_count
    )
    |> put_limit(:gateway_groups, account.limits.gateway_groups_count, gateway_groups_count)
  end

  defp put_limit(limits, _key, nil, _used), do: limits

  defp put_limit(limits, key, total, used) do
    Map.put(limits, key, %{
      used: used,
      available: max(0, total - used),
      total: total
    })
  end
end
