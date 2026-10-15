defmodule Portal.Workers.AccountInactivityReminder do
  @moduledoc """
  Oban worker that sends one inactivity reminder to the admins of a Starter account.

  An `"inactive"` reminder needs a year without activity. A `"default"`
  reminder, queued by hand from `Portal.Ops`, needs an account with no activity
  or setup beyond what sign-up creates. Both are checked again at send time.
  The two-week reminder period starts only after the mail provider accepts the
  email, so a failed send never starts the deletion clock.
  """

  use Oban.Worker,
    queue: :outbound_emails,
    max_attempts: 3,
    unique: [
      period: :infinity,
      states: :incomplete,
      keys: [:account_id]
    ]

  alias Portal.Mailer
  alias Portal.Mailer.Notifications
  alias __MODULE__.Database
  require Logger

  @batch_size 100

  @doc """
  Queues reminders for up to 100 accounts with no activity for a year.
  """
  def enqueue_inactive(now) do
    now
    |> Database.inactive_account_ids(@batch_size)
    |> enqueue("inactive")
  end

  @doc """
  Starter accounts with no surviving activity and no setup beyond sign-up,
  oldest first.
  """
  def default_accounts_query, do: Database.default_accounts_query()

  @doc """
  Queues reminders for up to 100 accounts of `default_accounts_query/0`.
  """
  def enqueue_default do
    @batch_size
    |> Database.default_account_ids()
    |> enqueue("default")
  end

  @impl Oban.Worker
  def perform(%Oban.Job{id: job_id, args: %{"account_id" => account_id, "reason" => reason}}) do
    now = DateTime.utc_now()

    case Database.fetch_account_and_recipients(account_id, reason, now) do
      {:ok, nil} ->
        :ok

      {:ok, {account, []}} ->
        Logger.warning("No admin actors found for account inactivity reminder",
          account_id: account.id
        )

        :ok

      {:ok, {account, recipients}} ->
        deliver(account, reason, recipients, job_id, now)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp enqueue(account_ids, reason) do
    Enum.reduce_while(account_ids, {:ok, 0}, fn account_id, {:ok, count} ->
      %{"account_id" => account_id, "reason" => reason}
      |> new()
      |> Oban.insert()
      |> case do
        {:ok, %{conflict?: true}} -> {:cont, {:ok, count}}
        {:ok, _job} -> {:cont, {:ok, count + 1}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp deliver(account, reason, recipients, job_id, checked_at) do
    {:ok, operation_id} = Ecto.UUID.load(<<0::64, job_id::64>>)

    account
    |> Notifications.account_inactivity_reminder_email(recipients, reason)
    |> Swoosh.Email.put_provider_option(:operation_id, operation_id)
    |> Mailer.deliver_secondary_with_email()
    |> record_delivery(account, checked_at)
  end

  # An empty response means every recipient was suppressed, so nothing was sent.
  defp record_delivery({{:ok, response}, _email}, _account, _checked_at)
       when map_size(response) == 0 do
    :ok
  end

  defp record_delivery({{:ok, response}, email}, account, checked_at) do
    message_id = response[:id] || response["id"]

    case Database.record_reminder(account, message_id, email, checked_at) do
      {:ok, _account} ->
        :ok

      {:error, reason} ->
        Logger.error("Failed to record account inactivity reminder; email was already sent",
          account_id: account.id,
          reason: inspect(reason)
        )

        {:error, reason}
    end
  end

  defp record_delivery({{:error, reason}, _email}, account, _checked_at) do
    Logger.error("Account inactivity reminder delivery failed",
      account_id: account.id,
      reason: inspect(reason)
    )

    {:error, reason}
  end

  defmodule Database do
    import Ecto.Query

    alias Portal.Account
    alias Portal.Actor
    alias Portal.Mailer
    alias Portal.Safe
    alias Portal.Workers.AccountInactivityReminder
    alias Portal.Workers.RollupAccountActivity

    def inactive_account_ids(now, limit) do
      eligible_query()
      |> where([account: a], is_nil(a.inactivity_reminded_at))
      |> where([account: a], a.last_active_at <= ^inactive_since(now))
      |> with_contactable_admin()
      |> without_pending_reminder()
      |> order_by([account: a], asc: a.last_active_at, asc: a.id)
      |> select([account: a], a.id)
      |> limit(^limit)
      |> Safe.unscoped()
      |> Safe.all()
    end

    def default_accounts_query do
      default_accounts()
      |> without_pending_reminder()
      |> order_by([account: a], asc: a.inserted_at, asc: a.id)
    end

    def default_account_ids(limit) do
      default_accounts_query()
      |> select([account: a], a.id)
      |> limit(^limit)
      |> Safe.unscoped()
      |> Safe.all()
    end

    def fetch_account_and_recipients(account_id, reason, now) do
      Safe.transact(fn ->
        account =
          eligible_query()
          |> where([account: a], a.id == ^account_id)
          |> lock("FOR UPDATE")
          |> Safe.unscoped()
          |> Safe.one()

        {:ok, maybe_recipients(account, reason, now)}
      end)
    end

    # Activity after `checked_at` clears the reminder on the next rollup.
    def record_reminder(account, message_id, email, checked_at) do
      Safe.transact(fn ->
        with {:ok, _entry} <- maybe_track_delivery(account, message_id, email) do
          account
          |> Ecto.Changeset.change(inactivity_reminded_at: checked_at)
          |> Account.changeset()
          |> Safe.unscoped()
          |> Safe.update()
        end
      end)
    end

    defp maybe_recipients(nil, _reason, _now), do: nil

    defp maybe_recipients(account, reason, now) do
      account = RollupAccountActivity.refresh(account, now)

      if is_nil(account.inactivity_reminded_at) and eligible?(account, reason, now) do
        {account, admin_emails(account.id)}
      end
    end

    defp eligible?(account, "inactive", now) do
      eligible_query()
      |> where([account: a], a.id == ^account.id and is_nil(a.inactivity_reminded_at))
      |> where([account: a], a.last_active_at <= ^inactive_since(now))
      |> Safe.unscoped()
      |> Safe.exists?()
    end

    # The running job must not exclude its own account as a pending reminder.
    defp eligible?(account, "default", _now) do
      default_accounts()
      |> where([account: a], a.id == ^account.id)
      |> Safe.unscoped()
      |> Safe.exists?()
    end

    defp inactive_since(now), do: DateTime.shift(now, year: -1)

    defp maybe_track_delivery(account, message_id, email) when is_binary(message_id) do
      recipients =
        for {_name, address} <- List.wrap(email.to) ++ List.wrap(email.cc) ++ List.wrap(email.bcc),
            do: address

      Mailer.insert_tracked_delivery(account.id, message_id, email.subject, recipients)
    end

    defp maybe_track_delivery(_account, _message_id, _email), do: {:ok, nil}

    defp admin_emails(account_id) do
      from(a in Actor,
        where: a.account_id == ^account_id,
        where: a.type == :account_admin_user,
        where: a.is_disabled == false,
        where: not is_nil(a.email),
        select: a.email,
        distinct: true
      )
      |> Safe.unscoped()
      |> Safe.all()
    end

    defp eligible_query do
      from(a in Account,
        as: :account,
        where: fragment("?->'stripe'->>'product_name' = 'Starter'", a.metadata),
        where: a.is_disabled == false,
        where: is_nil(a.scheduled_deletion_at),
        where: is_nil(a.lock_enabled_at)
      )
    end

    defp default_accounts do
      eligible_query()
      |> where([account: a], is_nil(a.inactivity_reminded_at))
      |> with_contactable_admin()
      |> where(
        [account: a],
        not exists(from(x in Actor, where: x.account_id == parent_as(:account).id, offset: 1))
      )
      |> without(Portal.SessionLog)
      |> without(Portal.PortalSession)
      |> without(Portal.APIRequestLog)
      |> without(Portal.Device)
      |> without(Portal.ClientToken)
      |> without(Portal.GatewayToken)
      |> without(Portal.APIToken)
      |> without(Portal.OAuthToken)
      |> without(Portal.OAuthGrant)
      |> without(Portal.Directory)
      |> without_custom_resources()
      |> without_custom_groups()
      |> without_custom_sites()
      |> without_custom_policies()
      |> without_configured_sso()
    end

    defp with_contactable_admin(query) do
      admins =
        from(x in Actor,
          as: :admin,
          where: x.account_id == parent_as(:account).id,
          where: x.type == :account_admin_user,
          where: x.is_disabled == false,
          where: not is_nil(x.email),
          where: not like(x.email, "%@firezone.invalid"),
          where:
            not exists(
              from(s in Portal.EmailSuppression,
                where: s.email == fragment("lower(?)", parent_as(:admin).email)
              )
            )
        )

      where(query, exists(admins))
    end

    defp without_pending_reminder(query) do
      jobs =
        Oban.Job.query(
          worker: AccountInactivityReminder,
          state: Oban.Job.unique_states(:incomplete)
        )

      where(
        query,
        not exists(
          from(j in jobs,
            where: fragment("?->>'account_id' = ?::text", j.args, parent_as(:account).id)
          )
        )
      )
    end

    defp without(query, schema) do
      where(
        query,
        not exists(from(r in schema, where: r.account_id == parent_as(:account).id))
      )
    end

    # Sign-up creates the Internet Resource and the "My devices" pool.
    defp without_custom_resources(query) do
      own_devices = Portal.Resource.DeviceMembershipCriteria.own_devices()

      where(
        query,
        not exists(
          from(r in Portal.Resource,
            where: r.account_id == parent_as(:account).id,
            where: r.type != :internet,
            where:
              r.type != :device_pool or r.name != "My devices" or
                r.device_membership_criteria != ^own_devices
          )
        )
      )
    end

    defp without_custom_groups(query) do
      where(
        query,
        not exists(
          from(g in Portal.Group,
            where: g.account_id == parent_as(:account).id,
            where: g.name not in ["Everyone", "Account owner"]
          )
        )
      )
    end

    defp without_custom_sites(query) do
      where(
        query,
        not exists(
          from(s in Portal.Site,
            where: s.account_id == parent_as(:account).id,
            where: s.managed_by == :account,
            where: s.name != "Default Site"
          )
        )
      )
    end

    # Sign-up grants the "Account owner" group access to the "My devices" pool.
    defp without_custom_policies(query) do
      where(
        query,
        not exists(
          from(p in Portal.Policy,
            join: r in Portal.Resource,
            on: r.id == p.resource_id and r.account_id == p.account_id,
            left_join: g in Portal.Group,
            on: g.id == p.group_id and g.account_id == p.account_id,
            where: p.account_id == parent_as(:account).id,
            where:
              r.type != :device_pool or r.name != "My devices" or
                is_nil(g.id) or g.name != "Account owner"
          )
        )
      )
    end

    defp without_configured_sso(query) do
      where(
        query,
        not exists(
          from(p in Portal.AuthProvider,
            where: p.account_id == parent_as(:account).id,
            where: p.type in [:oidc, :entra, :okta]
          )
        )
      )
    end
  end
end
