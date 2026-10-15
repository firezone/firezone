defmodule Portal.Workers.RollupAccountActivity do
  @moduledoc """
  Cron worker that records when each account was last active. Runs daily.

  Session logs, API request logs, device and token timestamps, and live
  presence are coalesced into `accounts.last_active_at`, so nothing is written
  to the account on every connection. A watermark row lets missed runs catch
  up without rescanning all retained logs.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [period: :infinity, states: :incomplete]

  alias Portal.Account
  alias Portal.Presence
  alias __MODULE__.Database

  @impl Oban.Worker
  def perform(_job) do
    case Database.rollup(DateTime.utc_now(), online_account_ids()) do
      {:ok, _count} -> :ok
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Records the activity of one account that is newer than its last rollup or
  its inactivity reminder. The caller must hold a row lock on the account.
  """
  def refresh(%Account{} = account, now) do
    Database.refresh(account, now, online?(account.id))
  end

  @doc """
  Whether the rollup ran recently enough to decide that an account is inactive.
  """
  def current?(now), do: Database.current?(now)

  defp online?(account_id) do
    Presence.Devices.online_ids(account_id) != [] or
      account_id
      |> Database.actor_ids()
      |> Enum.any?(&(Presence.PortalSessions.online_session_ids(&1) != []))
  end

  # A gateway that stays connected for a year has no new connection event.
  defp online_account_ids do
    topics =
      Portal.Presence_shard0
      |> :ets.tab2list()
      |> Enum.map(fn {{topic, _pid, _id}, _meta, _clock} -> topic end)
      |> Enum.uniq()
      |> Enum.filter(&(map_size(Presence.list(&1)) > 0))

    device_account_ids = for "presences:account_devices:" <> id <- topics, do: id
    portal_actor_ids = for "presences:portal_sessions:" <> id <- topics, do: id

    Enum.uniq(device_account_ids ++ Database.actor_account_ids(portal_actor_ids))
  end

  defmodule Database do
    import Ecto.Query

    alias Portal.Account
    alias Portal.AccountActivityRollup
    alias Portal.Actor
    alias Portal.Safe

    # Session and API request log partitions are kept for 121 days.
    @retained_history_days 120
    @stale_after_days 2

    def rollup(now, online_account_ids) do
      Safe.transact(fn ->
        rollup = locked_rollup()

        with {:ok, _} <- maybe_restart_observation(rollup.processed_until, now),
             {:ok, %{num_rows: count}} <-
               record_activity(rollup.processed_until, now, online_account_ids),
             {:ok, _} <- advance_watermark(rollup, now) do
          {:ok, count}
        end
      end)
    end

    def refresh(%Account{} = account, now, online?) do
      {:ok, %{rows: [[latest]]}} =
        Safe.unscoped()
        |> Safe.query(
          """
          SELECT max(active_at) FROM (
            SELECT max(timestamp) AS active_at FROM session_logs WHERE account_id = $1 AND timestamp > $2
            UNION ALL SELECT max(inserted_at) FROM api_request_logs WHERE account_id = $1 AND inserted_at > $2
            UNION ALL SELECT max(last_seen_at) FROM devices WHERE account_id = $1 AND last_seen_at > $2
            UNION ALL SELECT max(inserted_at) FROM portal_sessions WHERE account_id = $1 AND inserted_at > $2
            UNION ALL SELECT max(last_seen_at) FROM api_tokens WHERE account_id = $1 AND last_seen_at > $2
            UNION ALL SELECT max(last_seen_at) FROM oauth_tokens WHERE account_id = $1 AND last_seen_at > $2
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

    def current?(now) do
      stale_before = DateTime.add(now, -@stale_after_days, :day)

      from(r in AccountActivityRollup, where: r.processed_until >= ^stale_before)
      |> Safe.unscoped()
      |> Safe.exists?()
    end

    def actor_ids(account_id) do
      from(a in Actor, where: a.account_id == ^account_id, select: a.id)
      |> Safe.unscoped()
      |> Safe.all()
    end

    def actor_account_ids([]), do: []

    def actor_account_ids(actor_ids) do
      from(a in Actor, where: a.id in ^actor_ids, select: a.account_id, distinct: true)
      |> Safe.unscoped()
      |> Safe.all()
    end

    defp locked_rollup do
      from(r in AccountActivityRollup, lock: "FOR UPDATE")
      |> Safe.unscoped()
      |> Safe.one!()
    end

    # Once downtime outlasts log retention, missing logs no longer prove
    # inactivity, so every account starts a new observation period.
    defp maybe_restart_observation(processed_until, now) do
      if DateTime.diff(now, processed_until) > @retained_history_days * 86_400 do
        {count, _} =
          from(a in Account, where: is_nil(a.scheduled_deletion_at))
          |> Safe.unscoped()
          |> Safe.update_all(set: [last_active_at: now, inactivity_reminded_at: nil])

        {:ok, count}
      else
        {:ok, 0}
      end
    end

    # The one-day overlap catches log rows committed after the previous run.
    defp record_activity(processed_until, now, online_account_ids) do
      Safe.unscoped()
      |> Safe.query(
        """
        WITH activity AS (
          SELECT account_id, max(timestamp) AS active_at FROM session_logs
          WHERE timestamp >= $1 AND timestamp <= $2 GROUP BY account_id
          UNION ALL
          SELECT account_id, max(inserted_at) FROM api_request_logs
          WHERE inserted_at >= $1 AND inserted_at <= $2 GROUP BY account_id
          UNION ALL
          SELECT account_id, max(last_seen_at) FROM devices
          WHERE last_seen_at >= $1 AND last_seen_at <= $2 GROUP BY account_id
          UNION ALL
          SELECT account_id, max(last_seen_at) FROM api_tokens
          WHERE last_seen_at >= $1 AND last_seen_at <= $2 GROUP BY account_id
          UNION ALL
          SELECT account_id, max(last_seen_at) FROM oauth_tokens
          WHERE last_seen_at >= $1 AND last_seen_at <= $2 GROUP BY account_id
          UNION ALL
          SELECT unnest($3::uuid[]), $2::timestamptz
        ), latest AS (
          SELECT account_id, max(active_at) AS active_at FROM activity GROUP BY account_id
        )
        UPDATE accounts a
        SET last_active_at = l.active_at,
          inactivity_reminded_at = CASE
            WHEN l.active_at > a.inactivity_reminded_at THEN NULL
            ELSE a.inactivity_reminded_at
          END
        FROM latest l
        WHERE a.id = l.account_id AND l.active_at > a.last_active_at
        """,
        [
          DateTime.add(processed_until, -1, :day),
          now,
          Enum.map(online_account_ids, &Ecto.UUID.dump!/1)
        ]
      )
    end

    defp advance_watermark(rollup, now) do
      rollup
      |> Ecto.Changeset.change(processed_until: Enum.max([rollup.processed_until, now], DateTime))
      |> AccountActivityRollup.changeset()
      |> Safe.unscoped()
      |> Safe.update()
    end
  end
end
