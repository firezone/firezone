defmodule API.AccountJSON do
  alias __MODULE__.DB

  @doc """
  Render a single Account
  """
  def show(%{account: account}) do
    %{data: data(account)}
  end

  defp data(%Domain.Account{} = account) do
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
    users_count = DB.count_users_for_account(account)
    monthly_active_users_count = DB.count_1m_active_users_for_account(account)
    service_accounts_count = DB.count_service_accounts_for_account(account)
    admin_users_count = DB.count_account_admin_users_for_account(account)
    sites_count = DB.count_groups_for_account(account)

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
    |> put_limit(:sites, account.limits.sites_count, sites_count)
  end

  defp put_limit(limits, _key, nil, _used), do: limits

  defp put_limit(limits, key, total, used) do
    Map.put(limits, key, %{
      used: used,
      available: max(0, total - used),
      total: total
    })
  end

  defmodule DB do
    import Ecto.Query
    alias Domain.Safe
    alias Domain.Actor
    alias Domain.Client

    def count_users_for_account(account) do
      from(a in Actor,
        where: a.account_id == ^account.id,
        where: is_nil(a.disabled_at),
        where: a.type in [:account_admin_user, :account_user]
      )
      |> Safe.unscoped()
      |> Safe.aggregate(:count)
    end

    def count_service_accounts_for_account(account) do
      from(a in Actor,
        where: a.account_id == ^account.id,
        where: is_nil(a.disabled_at),
        where: a.type == :service_account
      )
      |> Safe.unscoped()
      |> Safe.aggregate(:count)
    end

    def count_account_admin_users_for_account(account) do
      from(a in Actor,
        where: a.account_id == ^account.id,
        where: is_nil(a.disabled_at),
        where: a.type == :account_admin_user
      )
      |> Safe.unscoped()
      |> Safe.aggregate(:count)
    end

    def count_1m_active_users_for_account(account) do
      from(c in Client, as: :clients)
      |> where([clients: c], c.account_id == ^account.id)
      |> where([clients: c], c.last_seen_at > ago(1, "month"))
      |> join(:inner, [clients: c], a in Actor, on: c.actor_id == a.id, as: :actor)
      |> where([actor: a], is_nil(a.disabled_at))
      |> where([actor: a], a.type in [:account_user, :account_admin_user])
      |> select([clients: c], c.actor_id)
      |> distinct(true)
      |> Safe.unscoped()
      |> Safe.aggregate(:count)
    end

    def count_groups_for_account(account) do
      from(g in Domain.Site,
        where: g.account_id == ^account.id,
        where: g.managed_by == :account
      )
      |> Safe.unscoped()
      |> Safe.aggregate(:count)
    end
  end
end
