defmodule Portal.Workers.SweepInactiveAccounts do
  @moduledoc """
  Cron worker that moves inactive Starter accounts toward deletion. Runs every 5 minutes.

  Accounts still inactive two weeks after their reminder are disabled and
  scheduled for deletion with the usual seven-day grace period. Accounts with
  no activity for a year get a reminder job. Nothing happens while the daily
  activity rollup is stale.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [period: :infinity, states: :incomplete]

  alias Portal.Workers.AccountInactivityReminder
  alias Portal.Workers.RollupAccountActivity
  alias __MODULE__.Database
  require Logger

  @impl Oban.Worker
  def perform(_job) do
    now = DateTime.utc_now()

    if RollupAccountActivity.current?(now) do
      with :ok <- schedule_expired_deletions(now),
           {:ok, count} <- AccountInactivityReminder.enqueue_inactive(now) do
        Logger.info("Queued account inactivity reminders", count: count)
        :ok
      end
    else
      {:error, :activity_rollup_stale}
    end
  end

  defp schedule_expired_deletions(now) do
    now
    |> Database.expired_reminder_account_ids()
    |> Enum.reduce_while(:ok, fn account_id, :ok ->
      case Database.schedule_deletion(account_id, now) do
        {:ok, _result} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defmodule Database do
    import Ecto.Query

    alias Portal.Account
    alias Portal.Actor
    alias Portal.Mailer
    alias Portal.Mailer.Notifications
    alias Portal.Safe
    alias Portal.Workers.AccountDeletionReminder
    alias Portal.Workers.RollupAccountActivity

    @reminder_period_days 14
    @deletion_grace_period_days 7

    def expired_reminder_account_ids(now) do
      deadline = DateTime.add(now, -@reminder_period_days, :day)

      from(a in Account,
        where: is_nil(a.scheduled_deletion_at),
        where: a.inactivity_reminded_at <= ^deadline,
        select: a.id
      )
      |> Safe.unscoped()
      |> Safe.all()
    end

    def schedule_deletion(account_id, now) do
      Safe.transact(fn ->
        from(a in Account,
          where: a.id == ^account_id,
          where: is_nil(a.scheduled_deletion_at),
          lock: "FOR UPDATE"
        )
        |> Safe.unscoped()
        |> Safe.one()
        |> maybe_schedule_deletion(now)
      end)
    end

    defp maybe_schedule_deletion(nil, _now), do: {:ok, :skipped}

    defp maybe_schedule_deletion(account, now) do
      account = RollupAccountActivity.refresh(account, now)

      cond do
        is_nil(account.inactivity_reminded_at) ->
          {:ok, :skipped}

        not eligible?(account) ->
          clear_reminder(account)

        DateTime.diff(now, account.inactivity_reminded_at, :day) >= @reminder_period_days ->
          disable_and_schedule_deletion(account, now)

        true ->
          {:ok, :skipped}
      end
    end

    # Upgrading, disabling, or locking an account ends the inactivity cleanup.
    defp eligible?(account) do
      Portal.Billing.plan_type(account) == :starter and
        account.is_disabled == false and
        is_nil(account.lock_enabled_at)
    end

    defp clear_reminder(account) do
      account
      |> Ecto.Changeset.change(inactivity_reminded_at: nil)
      |> Account.changeset()
      |> Safe.unscoped()
      |> Safe.update()
    end

    defp disable_and_schedule_deletion(account, now) do
      changeset =
        account
        |> Ecto.Changeset.change(
          is_disabled: true,
          disabled_reason: "Account inactivity",
          scheduled_deletion_at: DateTime.add(now, @deletion_grace_period_days, :day)
        )
        |> Account.changeset()

      with {:ok, account} <- changeset |> Safe.unscoped() |> Safe.update(),
           {:ok, _job} <- insert_deletion_reminder_job(account),
           {:ok, _result} <- notify_admins(account) do
        {:ok, account}
      end
    end

    defp insert_deletion_reminder_job(account) do
      %{"account_id" => account.id}
      |> AccountDeletionReminder.new(
        scheduled_at: DateTime.add(account.scheduled_deletion_at, -48, :hour)
      )
      |> Oban.insert()
    end

    defp notify_admins(account) do
      case admin_emails(account.id) do
        [] ->
          {:ok, :no_recipients}

        recipients ->
          account
          |> Notifications.account_scheduled_for_inactivity_deletion_email(recipients)
          |> Mailer.enqueue()
      end
    end

    defp admin_emails(account_id) do
      from(a in Actor,
        where: a.account_id == ^account_id,
        where: a.type == :account_admin_user,
        where: a.is_disabled == false,
        select: a.email
      )
      |> Safe.unscoped()
      |> Safe.all()
    end
  end
end
