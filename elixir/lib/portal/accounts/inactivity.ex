defmodule Portal.Accounts.Inactivity do
  @moduledoc """
  Coalesces account activity and manages inactivity warnings. Lifecycle deadlines
  live on the account; a periodic sweep advances them, never a future Oban job.
  """
  alias __MODULE__.Database
  alias Portal.Workers.AccountInactivityReminder

  @batch_size 100

  def rollup(now \\ DateTime.utc_now()) do
    Database.rollup(now, online_account_ids())
  end

  def default_accounts_query, do: Database.default_accounts_query()

  def deliver_reminder(job), do: Database.deliver_reminder(job)

  def queue_default_reminders do
    Database.default_accounts_query()
    |> Database.account_ids(@batch_size)
    |> queue_reminders("default")
  end

  def sweep(now \\ DateTime.utc_now()) do
    with :ok <- Database.ensure_rollup_current(now),
         {:ok, _} <- advance_warnings(now, MapSet.new(online_account_ids())) do
      Database.inactive_account_ids(now, @batch_size)
      |> queue_reminders("inactive")
    end
  end

  defp advance_warnings(now, online) do
    Enum.reduce_while(Database.warned_account_ids(), {:ok, 0}, fn id, {:ok, count} ->
      advance_result(Database.advance_warning(id, now, MapSet.member?(online, id)), count)
    end)
  end

  defp advance_result({:ok, _}, count), do: {:cont, {:ok, count + 1}}
  defp advance_result({:error, _} = error, _count), do: {:halt, error}

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

  # A continuously connected gateway must not become inactive just because its
  # last connection event is old. Read the existing cluster presence, once/day.
  def online_account_ids do
    topics =
      Portal.Presence_shard0
      |> :ets.tab2list()
      |> Enum.map(fn {{topic, _pid, _id}, _meta, _clock} -> topic end)
      |> Enum.uniq()
      |> Enum.filter(&(map_size(Portal.Presence.list(&1)) > 0))

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

    defp eligible_query do
      from(a in Account,
        as: :account,
        where: fragment("?->'stripe'->>'product_name' = 'Starter'", a.metadata),
        where: not a.is_disabled and is_nil(a.scheduled_deletion_at),
        where: is_nil(a.lock_enabled_at)
      )
    end

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
                where: fragment("lower(?) = lower(?)", s.email, parent_as(:admin).email)
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

    def warned_account_ids do
      from(a in Account, where: is_nil(a.scheduled_deletion_at))
      |> where([a], not is_nil(a.inactivity_reminded_at))
      |> select([a], a.id)
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

    def locked_account(id) do
      eligible_query()
      |> where([a], a.id == ^id)
      |> lock("FOR UPDATE")
      |> Safe.unscoped()
      |> Safe.one()
    end

    def refresh_activity(account, now, online?) do
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
          |> Safe.unscoped()
          |> Safe.update()

        account
      else
        account
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

    defp advance_locked_warning(nil, _now, _online?), do: {:ok, :skipped}

    defp advance_locked_warning(account, now, online?) do
      account = account |> refresh_activity(now, online?) |> clear_ineligible_warning()

      if account.inactivity_reminded_at &&
           DateTime.diff(now, account.inactivity_reminded_at) >= 14 * 86_400 do
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
             account |> Ecto.Changeset.change(changes) |> Safe.unscoped() |> Safe.update(),
           {:ok, _} <-
             account |> AccountInactivity.scheduled_email(recipients) |> Mailer.enqueue() do
        {:ok, account}
      end
    end

    def reminder_eligible?(account, "default", _now) do
      # The executing reminder must not exclude itself from the preview query.
      default_accounts_query(false)
      |> exclude(:order_by)
      |> where([a], a.id == ^account.id)
      |> Safe.unscoped()
      |> Safe.exists?()
    end

    def reminder_eligible?(account, "inactive", now) do
      eligible_query()
      |> where([a], a.id == ^account.id and is_nil(a.inactivity_reminded_at))
      |> where(
        [a],
        fragment("? <= ?::timestamptz - interval '12 months'", a.last_active_at, ^now)
      )
      |> Safe.unscoped()
      |> Safe.exists?()
    end

    def admin_emails(id) do
      from(a in Actor,
        where: a.account_id == ^id and a.type == :account_admin_user,
        where: not a.is_disabled and not is_nil(a.email),
        select: a.email,
        distinct: true
      )
      |> Safe.unscoped()
      |> Safe.all()
    end

    defp mark_reminded(account) do
      account
      |> Ecto.Changeset.change(inactivity_reminded_at: DateTime.utc_now())
      |> Safe.unscoped()
      |> Safe.update()
    end

    def deliver_reminder(%Oban.Job{id: job_id, args: %{"account_id" => id, "reason" => reason}}) do
      now = DateTime.utc_now()
      online? = Portal.Presence.Devices.online_ids(id) != []

      Safe.transact(fn ->
        send_locked_reminder(locked_account(id), reason, now, online?, job_id)
      end)
    end

    defp send_locked_reminder(nil, _reason, _now, _online?, _job_id), do: {:ok, :skipped}

    defp send_locked_reminder(account, reason, now, online?, job_id) do
      account = refresh_activity(account, now, online?)

      if is_nil(account.inactivity_reminded_at) and reminder_eligible?(account, reason, now) do
        deliver_warning(account, reason, job_id, admin_emails(account.id))
      else
        {:ok, :skipped}
      end
    end

    defp deliver_warning(_account, _reason, _job_id, []), do: {:ok, :no_recipients}

    defp deliver_warning(account, reason, job_id, recipients) do
      {:ok, operation_id} = Ecto.UUID.load(<<0::64, job_id::64>>)

      email =
        account
        |> AccountInactivity.reminder_email(recipients, reason)
        |> Swoosh.Email.put_provider_option(:operation_id, operation_id)

      Mailer.deliver_secondary_with_email(email) |> record_reminder_delivery(account)
    end

    defp record_reminder_delivery({{:ok, response}, _email}, _account)
         when map_size(response) == 0,
         do: {:ok, :not_sent}

    defp record_reminder_delivery({{:error, reason}, _email}, _account), do: {:error, reason}

    defp record_reminder_delivery({{:ok, response}, email}, account) do
      persist_reminder(response[:id] || response["id"], email, account)
    end

    defp persist_reminder(id, email, account) when is_binary(id) do
      recipients = for {_name, address} <- email.to ++ email.cc ++ email.bcc, do: address

      with {:ok, _} <- Mailer.insert_tracked_delivery(account.id, id, email.subject, recipients),
           {:ok, _} <- mark_reminded(account) do
        {:ok, :sent}
      end
    end

    defp persist_reminder(_id, _email, _account), do: {:error, :missing_message_id}

    defp query(sql, params), do: Safe.unscoped() |> Safe.query(sql, params)
  end
end
