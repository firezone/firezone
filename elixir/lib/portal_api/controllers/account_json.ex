defmodule PortalAPI.AccountJSON do
  PortalAPI.JSON.verify!(__MODULE__, Portal.Account, PortalAPI.Schemas.Account.Schema,
    computed: [:limits],
    # ingest_signing_key is credential material and must never leave the portal.
    internal: [
      :admins_limit_exceeded,
      :config,
      :disabled_reason,
      :features,
      :ingest_signing_key,
      :inserted_at,
      :is_disabled,
      :lock_enabled_at,
      :metadata,
      :scheduled_deletion_at,
      :seats_limit_exceeded,
      :service_accounts_limit_exceeded,
      :sites_limit_exceeded,
      :updated_at,
      :users_limit_exceeded,
      :warning_last_sent_at
    ]
  )

  alias __MODULE__.Database

  @doc """
  Render a single Account
  """
  def show(%{account: account}) do
    %{data: data(account)}
  end

  defp data(%Portal.Account{} = account) do
    PortalAPI.JSON.render(account, PortalAPI.Schemas.Account.Schema, %{limits: build_limits(account)})
  end

  defp build_limits(account) do
    # Get current usage counts
    users_count = Database.count_users_for_account(account)
    monthly_active_users_count = Database.count_1m_active_users_for_account(account)
    service_accounts_count = Database.count_service_accounts_for_account(account)
    admin_users_count = Database.count_account_admin_users_for_account(account)
    sites_count = Database.count_groups_for_account(account)

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

  defmodule Database do
    import Ecto.Query
    alias Portal.Safe
    alias Portal.Actor
    alias Portal.Device

    def count_users_for_account(account) do
      from(a in Actor,
        where: a.account_id == ^account.id,
        where: a.is_disabled == false,
        where: a.type in [:account_admin_user, :account_user]
      )
      |> Safe.unscoped()
      |> Safe.aggregate(:count)
    end

    def count_service_accounts_for_account(account) do
      from(a in Actor,
        where: a.account_id == ^account.id,
        where: a.is_disabled == false,
        where: a.type == :service_account
      )
      |> Safe.unscoped()
      |> Safe.aggregate(:count)
    end

    def count_account_admin_users_for_account(account) do
      from(a in Actor,
        where: a.account_id == ^account.id,
        where: a.is_disabled == false,
        where: a.type == :account_admin_user
      )
      |> Safe.unscoped()
      |> Safe.aggregate(:count)
    end

    def count_1m_active_users_for_account(account) do
      from(d in Device, as: :devices)
      |> where([devices: d], d.type == :client)
      |> where([devices: d], d.account_id == ^account.id)
      |> where([devices: d], d.last_seen_at > ago(1, "month"))
      |> join(:inner, [devices: d], a in Actor,
        on: d.actor_id == a.id and d.account_id == a.account_id,
        as: :actor
      )
      |> where([actor: a], a.is_disabled == false)
      |> where([actor: a], a.type in [:account_user, :account_admin_user])
      |> select([devices: d], d.actor_id)
      |> distinct(true)
      |> Safe.unscoped()
      |> Safe.aggregate(:count)
    end

    def count_groups_for_account(account) do
      from(g in Portal.Site,
        where: g.account_id == ^account.id,
        where: g.managed_by == :account
      )
      |> Safe.unscoped()
      |> Safe.aggregate(:count)
    end
  end
end
