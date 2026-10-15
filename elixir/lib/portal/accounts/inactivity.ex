defmodule Portal.Accounts.Inactivity do
  @moduledoc """
  Coalesces account activity and manages inactivity warnings. Lifecycle deadlines
  live on the account; a periodic sweep advances them, never a future Oban job.
  """
  alias __MODULE__.Database
  alias Portal.Mailer
  alias Portal.Mailer.AccountInactivity
  alias Portal.Presence
  alias Portal.Workers.AccountInactivityReminder

  @batch_size 100

  def rollup(now \\ DateTime.utc_now()) do
    Database.rollup(now, online_account_ids())
  end

  def default_accounts_query, do: Database.default_accounts_query()

  def queue_default_reminders do
    Database.default_accounts_query()
    |> Database.account_ids(@batch_size)
    |> queue_reminders("default")
  end

  def sweep(now \\ DateTime.utc_now()) do
    with :ok <- Database.ensure_rollup_current(now),
         {:ok, _} <- advance_expired_warnings(now) do
      Database.inactive_account_ids(now, @batch_size)
      |> queue_reminders("inactive")
    end
  end

  # The provider call happens after the eligibility check commits, so a slow
  # provider never holds the account row lock.
  def deliver_reminder(%Oban.Job{id: job_id, args: %{"account_id" => id, "reason" => reason}}) do
    now = DateTime.utc_now()

    case Database.reminder_recipients(id, reason, now, online?(id)) do
      {:ok, {account, [_ | _] = recipients}} ->
        send_reminder(account, reason, recipients, job_id, now)

      {:ok, {_account, []}} ->
        {:ok, :no_recipients}

      {:ok, :skipped} ->
        {:ok, :skipped}

      {:error, _} = error ->
        error
    end
  end

  defp advance_expired_warnings(now) do
    Enum.reduce_while(Database.expired_warning_account_ids(now), {:ok, 0}, fn id, {:ok, count} ->
      case Database.advance_warning(id, now, online?(id)) do
        {:ok, _} -> {:cont, {:ok, count + 1}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp queue_reminders(ids, reason) do
    Enum.reduce_while(ids, {:ok, 0}, fn id, {:ok, count} ->
      case %{"account_id" => id, "reason" => reason}
           |> AccountInactivityReminder.new()
           |> Oban.insert() do
        {:ok, %{conflict?: true}} -> {:cont, {:ok, count}}
        {:ok, _job} -> {:cont, {:ok, count + 1}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp send_reminder(account, reason, recipients, job_id, checked_at) do
    {:ok, operation_id} = Ecto.UUID.load(<<0::64, job_id::64>>)

    account
    |> AccountInactivity.reminder_email(recipients, reason)
    |> Swoosh.Email.put_provider_option(:operation_id, operation_id)
    |> Mailer.deliver_secondary_with_email()
    |> record_reminder_delivery(account, checked_at)
  end

  defp record_reminder_delivery({{:ok, response}, _email}, _account, _checked_at)
       when map_size(response) == 0,
       do: {:ok, :not_sent}

  defp record_reminder_delivery({{:error, reason}, _email}, _account, _checked_at),
    do: {:error, reason}

  defp record_reminder_delivery({{:ok, response}, email}, account, checked_at) do
    case response[:id] || response["id"] do
      message_id when is_binary(message_id) ->
        recipients = for {_name, address} <- email.to ++ email.cc ++ email.bcc, do: address
        Database.record_reminder(account, message_id, email.subject, recipients, checked_at)

      _ ->
        {:error, :missing_message_id}
    end
  end

  defp online?(account_id) do
    Presence.Devices.online_ids(account_id) != [] or
      account_id
      |> Database.actor_ids()
      |> Enum.any?(&(Presence.PortalSessions.online_session_ids(&1) != []))
  end

  # A continuously connected gateway must not become inactive just because its
  # last connection event is old. Read the existing cluster presence, once/day.
  defp online_account_ids do
    topics =
      Portal.Presence_shard0
      |> :ets.tab2list()
      |> Enum.map(fn {{topic, _pid, _id}, _meta, _clock} -> topic end)
      |> Enum.uniq()
      |> Enum.filter(&(map_size(Presence.list(&1)) > 0))

    device_accounts =
      for "presences:account_devices:" <> id <- topics, do: id

    portal_actors = for "presences:portal_sessions:" <> id <- topics, do: id
    Enum.uniq(device_accounts ++ Database.actor_account_ids(portal_actors))
  end

  defmodule Database do
    import Ecto.Query
    alias Portal.{Account, Actor, Safe}
    alias Portal.Mailer
    alias Portal.Mailer.AccountInactivity
    alias Portal.Workers.AccountInactivityReminder

    @warning_period_days 14

    def default_accounts_query(include_pending \\ true) do
      eligible_query()
      |> where([a], is_nil(a.inactivity_reminded_at))
      |> with_contactable_admin()
      |> where(
        [a],
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
      |> without_custom_setup()
      |> maybe_without_pending_reminder(include_pending)
      |> order_by([a], asc: a.inserted_at, asc: a.id)
    end

    def account_ids(query, limit) do
      query |> select([a], a.id) |> limit(^limit) |> Safe.unscoped() |> Safe.all()
    end

    def inactive_account_ids(now, limit) do
      eligible_query()
      |> where([a], is_nil(a.inactivity_reminded_at))
      |> where(
        [a],
        fragment("? <= ?::timestamptz - interval '12 months'", a.last_active_at, ^now)
      )
      |> with_contactable_admin()
      |> without_pending_reminder()
      |> order_by([a], asc: a.last_active_at, asc: a.id)
      |> account_ids(limit)
    end

    def expired_warning_account_ids(now) do
      deadline = DateTime.add(now, -@warning_period_days, :day)

      from(a in Account,
        where: is_nil(a.scheduled_deletion_at) and a.inactivity_reminded_at <= ^deadline,
        select: a.id
      )
      |> Safe.unscoped()
      |> Safe.all()
    end

    def actor_ids(account_id) do
      from(a in Actor, where: a.account_id == ^account_id, select: a.id)
      |> Safe.unscoped()
      |> Safe.all()
    end

    def actor_account_ids([]), do: []

    def actor_account_ids(ids) do
      from(a in Actor, where: a.id in ^ids, select: a.account_id, distinct: true)
      |> Safe.unscoped()
      |> Safe.all()
    end

    def rollup(now, online_ids) do
      Safe.transact(fn ->
        with {:ok, %{rows: [[since]]}} <-
               query(
                 "SELECT processed_until FROM account_activity_rollups WHERE id FOR UPDATE",
                 []
               ),
             {:ok, _} <- recover_expired_history(since, now),
             {:ok, result} <-
               query(
                 """
                 WITH activity AS (
                   SELECT account_id, max(timestamp) AS active_at FROM session_logs
                   WHERE timestamp >= $1 AND timestamp <= $2 GROUP BY account_id
                   UNION ALL
                   SELECT account_id, max(inserted_at) FROM api_request_logs WHERE inserted_at >= $1 AND inserted_at <= $2 GROUP BY account_id
                   UNION ALL
                   SELECT account_id, max(last_seen_at) FROM devices WHERE last_seen_at >= $1 AND last_seen_at <= $2 GROUP BY account_id
                   UNION ALL
                   SELECT account_id, max(last_seen_at) FROM api_tokens WHERE last_seen_at >= $1 AND last_seen_at <= $2 GROUP BY account_id
                   UNION ALL
                   SELECT account_id, max(last_seen_at) FROM oauth_tokens WHERE last_seen_at >= $1 AND last_seen_at <= $2 GROUP BY account_id
                   UNION ALL
                   SELECT unnest($3::uuid[]), $2::timestamptz
                 ), latest AS (SELECT account_id, max(active_at) AS active_at FROM activity GROUP BY account_id)
                 UPDATE accounts a SET last_active_at = l.active_at,
                   inactivity_reminded_at = CASE WHEN l.active_at > a.inactivity_reminded_at THEN NULL ELSE a.inactivity_reminded_at END
                 FROM latest l WHERE a.id = l.account_id AND l.active_at > a.last_active_at
                 """,
                 [DateTime.add(since, -1, :day), now, Enum.map(online_ids, &Ecto.UUID.dump!/1)]
               ),
             {:ok, _} <-
               query(
                 "UPDATE account_activity_rollups SET processed_until = GREATEST(processed_until, $1) WHERE id",
                 [now]
               ) do
          {:ok, result.num_rows}
        end
      end)
    end

    def ensure_rollup_current(now) do
      case query(
             "SELECT processed_until >= $1::timestamptz - interval '2 days' FROM account_activity_rollups WHERE id",
             [now]
           ) do
        {:ok, %{rows: [[true]]}} -> :ok
        {:ok, _} -> {:error, :activity_rollup_stale}
        {:error, _} = error -> error
      end
    end

    def advance_warning(id, now, online?) do
      Safe.transact(fn ->
        account =
          from(a in Account,
            where: a.id == ^id and is_nil(a.scheduled_deletion_at),
            lock: "FOR UPDATE"
          )
          |> Safe.unscoped()
          |> Safe.one()

        advance_locked_warning(account, now, online?)
      end)
    end

    def reminder_recipients(id, reason, now, online?) do
      Safe.transact(fn ->
        id |> locked_account() |> locked_reminder_recipients(reason, now, online?)
      end)
    end

    # Activity after the eligibility check clears the warning on the next rollup.
    def record_reminder(account, message_id, subject, recipients, checked_at) do
      Safe.transact(fn ->
        with {:ok, _} <-
               Mailer.insert_tracked_delivery(account.id, message_id, subject, recipients),
             {:ok, _} <-
               account
               |> Ecto.Changeset.change(inactivity_reminded_at: checked_at)
               |> Account.changeset()
               |> Safe.unscoped()
               |> Safe.update() do
          {:ok, :sent}
        end
      end)
    end

    defp eligible_query do
      from(a in Account,
        as: :account,
        where: fragment("?->'stripe'->>'product_name' = 'Starter'", a.metadata),
        where: not a.is_disabled and is_nil(a.scheduled_deletion_at),
        where: is_nil(a.lock_enabled_at)
      )
    end

    defp with_contactable_admin(query) do
      admins =
        from(x in Actor,
          as: :admin,
          where: x.account_id == parent_as(:account).id,
          where: x.type == :account_admin_user and not x.is_disabled and not is_nil(x.email),
          where: fragment("?::text NOT LIKE '%@firezone.invalid'", x.email),
          where:
            not exists(
              from(s in Portal.EmailSuppression,
                where: s.email == fragment("lower(?)", parent_as(:admin).email)
              )
            )
        )

      where(query, exists(admins))
    end

    defp without_custom_setup(query) do
      query
      |> without_custom_resources()
      |> without_custom_groups()
      |> without_custom_sites()
      |> without_custom_policies()
      |> without_configured_sso()
    end

    defp without_custom_resources(query) do
      query
      |> where(
        [a],
        not exists(
          from(r in Portal.Resource,
            where: r.account_id == parent_as(:account).id,
            where: r.type != :internet,
            where:
              r.type != :device_pool or r.name != "My devices" or
                r.device_membership_criteria !=
                  ^Portal.Resource.DeviceMembershipCriteria.own_devices()
          )
        )
      )
    end

    defp without_custom_groups(query) do
      query
      |> where(
        [a],
        not exists(
          from(g in Portal.Group,
            where:
              g.account_id == parent_as(:account).id and
                g.name not in ["Everyone", "Account owner"]
          )
        )
      )
    end

    defp without_custom_sites(query) do
      query
      |> where(
        [a],
        not exists(
          from(s in Portal.Site,
            where: s.account_id == parent_as(:account).id and s.managed_by == :account,
            where: s.name != "Default Site"
          )
        )
      )
    end

    defp without_custom_policies(query) do
      query
      |> where(
        [a],
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
      query
      |> where(
        [a],
        not exists(
          from(p in Portal.AuthProvider,
            where: p.account_id == parent_as(:account).id and p.type in [:oidc, :entra, :okta]
          )
        )
      )
    end

    defp without(query, schema) do
      where(
        query,
        [a],
        not exists(from(r in schema, where: r.account_id == parent_as(:account).id))
      )
    end

    defp maybe_without_pending_reminder(query, false), do: query
    defp maybe_without_pending_reminder(query, true), do: without_pending_reminder(query)

    defp without_pending_reminder(query) do
      jobs =
        Oban.Job.query(
          worker: AccountInactivityReminder,
          state: Oban.Job.unique_states(:incomplete)
        )

      where(
        query,
        [a],
        not exists(
          from(j in jobs,
            where: fragment("?->>'account_id' = ?::text", j.args, parent_as(:account).id)
          )
        )
      )
    end

    # If downtime outlasts log retention, absence of logs is no longer evidence
    # of inactivity. Restart the observation period rather than delete users
    # whose activity may have been pruned while the rollup was unavailable.
    defp recover_expired_history(since, now) do
      if DateTime.diff(now, since) > 120 * 86_400 do
        query(
          """
          UPDATE accounts SET last_active_at = GREATEST(last_active_at, $1),
            inactivity_reminded_at = NULL
          WHERE scheduled_deletion_at IS NULL
          """,
          [now]
        )
      else
        {:ok, :history_retained}
      end
    end

    defp locked_account(id) do
      eligible_query()
      |> where([a], a.id == ^id)
      |> lock("FOR UPDATE")
      |> Safe.unscoped()
      |> Safe.one()
    end

    defp refresh_activity(account, now, online?) do
      {:ok, %{rows: [[latest]]}} =
        query(
          """
          SELECT max(active_at) FROM (
            SELECT max(timestamp) AS active_at FROM session_logs WHERE account_id=$1 AND timestamp > $2
            UNION ALL SELECT max(inserted_at) FROM api_request_logs WHERE account_id=$1 AND inserted_at > $2
            UNION ALL SELECT max(last_seen_at) FROM devices WHERE account_id=$1 AND last_seen_at > $2
            UNION ALL SELECT max(inserted_at) FROM portal_sessions WHERE account_id=$1 AND inserted_at > $2
            UNION ALL SELECT max(last_seen_at) FROM api_tokens WHERE account_id=$1 AND last_seen_at > $2
            UNION ALL SELECT max(last_seen_at) FROM oauth_tokens WHERE account_id=$1 AND last_seen_at > $2
          ) recent
          """,
          [Ecto.UUID.dump!(account.id), account.inactivity_reminded_at || account.last_active_at]
        )

      latest = if online?, do: now, else: latest

      if latest && DateTime.compare(latest, account.last_active_at) == :gt do
        {:ok, account} =
          account
          |> Ecto.Changeset.change(last_active_at: latest, inactivity_reminded_at: nil)
          |> Account.changeset()
          |> Safe.unscoped()
          |> Safe.update()

        account
      else
        account
      end
    end

    defp advance_locked_warning(nil, _now, _online?), do: {:ok, :skipped}

    defp advance_locked_warning(account, now, online?) do
      account = account |> refresh_activity(now, online?) |> clear_ineligible_warning()

      if account.inactivity_reminded_at &&
           DateTime.diff(now, account.inactivity_reminded_at, :day) >= @warning_period_days do
        schedule_deletion(account, now)
      else
        {:ok, :skipped}
      end
    end

    defp clear_ineligible_warning(account) do
      if Portal.Billing.plan_type(account) != :starter or account.is_disabled or
           account.lock_enabled_at do
        {:ok, account} =
          account
          |> Ecto.Changeset.change(inactivity_reminded_at: nil)
          |> Account.changeset()
          |> Safe.unscoped()
          |> Safe.update()

        account
      else
        account
      end
    end

    defp schedule_deletion(account, now) do
      recipients = admin_emails(account.id)

      changes = [
        is_disabled: true,
        disabled_reason: "Account inactivity",
        scheduled_deletion_at: DateTime.add(now, 7, :day)
      ]

      with {:ok, account} <-
             account
             |> Ecto.Changeset.change(changes)
             |> Account.changeset()
             |> Safe.unscoped()
             |> Safe.update(),
           {:ok, _} <-
             account |> AccountInactivity.scheduled_email(recipients) |> Mailer.enqueue() do
        {:ok, account}
      end
    end

    defp reminder_eligible?(account, "default", _now) do
      # The executing reminder must not exclude itself from the preview query.
      default_accounts_query(false)
      |> exclude(:order_by)
      |> where([a], a.id == ^account.id)
      |> Safe.unscoped()
      |> Safe.exists?()
    end

    defp reminder_eligible?(account, "inactive", now) do
      eligible_query()
      |> where([a], a.id == ^account.id and is_nil(a.inactivity_reminded_at))
      |> where(
        [a],
        fragment("? <= ?::timestamptz - interval '12 months'", a.last_active_at, ^now)
      )
      |> Safe.unscoped()
      |> Safe.exists?()
    end

    defp admin_emails(id) do
      from(a in Actor,
        where: a.account_id == ^id and a.type == :account_admin_user,
        where: not a.is_disabled and not is_nil(a.email),
        select: a.email,
        distinct: true
      )
      |> Safe.unscoped()
      |> Safe.all()
    end

    defp locked_reminder_recipients(nil, _reason, _now, _online?), do: {:ok, :skipped}

    defp locked_reminder_recipients(account, reason, now, online?) do
      account = refresh_activity(account, now, online?)

      if is_nil(account.inactivity_reminded_at) and reminder_eligible?(account, reason, now) do
        {:ok, {account, admin_emails(account.id)}}
      else
        {:ok, :skipped}
      end
    end

    defp query(sql, params), do: Safe.unscoped() |> Safe.query(sql, params)
  end
end
