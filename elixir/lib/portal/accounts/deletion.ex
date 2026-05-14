defmodule Portal.Accounts.Deletion do
  @moduledoc false

  alias Portal.Account
  alias Portal.Mailer
  alias Portal.Mailer.Notifications
  alias __MODULE__.Database
  require Logger

  def schedule_account_deletion(%Account{} = account, attrs, subject) do
    case Database.schedule_account_deletion(account, attrs, subject) do
      {:ok, {:transitioned, account}} -> enqueue_deletion_notification(account, subject)
      {:ok, {:unchanged, account}} -> {:ok, account}
      {:error, reason} -> {:error, reason}
    end
  end

  def cancel_account_deletion(%Account{} = account, subject) do
    case Database.cancel_account_deletion(account, subject) do
      {:ok, {:transitioned, account}} -> enqueue_cancellation_notification(account, subject)
      {:ok, {:unchanged, account}} -> {:ok, account}
      {:error, reason} -> {:error, reason}
    end
  end

  defp enqueue_deletion_notification(%Account{} = account, subject) do
    notify_admins(
      account,
      subject,
      :schedule,
      &Notifications.account_scheduled_for_deletion_email/3
    )
  end

  defp enqueue_cancellation_notification(%Account{} = account, subject) do
    notify_admins(
      account,
      subject,
      :cancel,
      &Notifications.account_deletion_aborted_email/3
    )
  end

  defp notify_admins(%Account{} = account, subject, action, email_fun) do
    admin_emails = Database.get_account_admin_emails(account.id, subject)

    case admin_emails do
      [] ->
        log_missing_admins(account, action)
        {:ok, account}

      admin_emails ->
        email = email_fun.(account, admin_emails, subject.context)
        enqueue_notification_email(email, account, admin_emails, action)
    end
  end

  defp enqueue_notification_email(email, %Account{} = account, admin_emails, action) do
    case Mailer.enqueue(email) do
      {:ok, _result} ->
        {:ok, account}

      {:error, reason} ->
        Logger.error("Failed to enqueue account deletion notification",
          account_id: account.id,
          action: action,
          recipient_count: length(admin_emails),
          reason: inspect(reason)
        )

        {:ok, account}
    end
  end

  defp log_missing_admins(%Account{} = account, action) do
    Logger.warning("No admin actors found for account deletion notification",
      account_id: account.id,
      action: action
    )
  end

  defmodule Database do
    import Ecto.Query

    alias Portal.Account
    alias Portal.Actor
    alias Portal.Safe
    alias Portal.Workers.AccountDeletionReminder
    alias Portal.Workers.DeleteAccount

    def schedule_account_deletion(%Account{} = account, attrs, subject) do
      Safe.transact(fn ->
        with {:ok, transition} <-
               transition_account_deletion(account, attrs, :schedule, subject),
             {:ok, _job} <- maybe_insert_delete_job(transition),
             {:ok, _job} <- maybe_insert_reminder_job(transition) do
          {:ok, transition}
        end
      end)
    end

    def cancel_account_deletion(%Account{} = account, subject) do
      Safe.transact(fn ->
        with {:ok, transition} <-
               transition_account_deletion(
                 account,
                 %{disabled_at: nil, scheduled_deletion_at: nil},
                 :cancel,
                 subject
               ),
             {:ok, _jobs} <- maybe_cancel_delete_jobs(transition),
             {:ok, _jobs} <- maybe_cancel_reminder_jobs(transition) do
          {:ok, transition}
        end
      end)
    end

    defp fetch_account(account_id, subject) do
      from(a in Account, where: a.id == ^account_id)
      |> Safe.scoped(subject, :replica)
      |> Safe.one()
      |> case do
        %Account{} = account -> {:ok, account}
        nil -> {:error, :unauthorized}
        {:error, :unauthorized} = error -> error
      end
    end

    defp transition_account_deletion(
           %Account{id: account_id},
           attrs,
           action,
          %{account: %{id: account_id}} = subject
         ) do
      now = DateTime.utc_now()

      query =
        from(a in Account,
          where: a.id == ^account_id,
          select: a
        )
        |> restrict_to_matching_transition(action)

      updates =
        attrs
        |> Map.take([:disabled_at, :scheduled_deletion_at])
        |> Map.put(:updated_at, now)

      case query |> Safe.scoped(subject) |> Safe.update_all(set: Map.to_list(updates)) do
        {1, [updated_account]} ->
          {:ok, {:transitioned, updated_account}}

        {0, _} ->
          with {:ok, account} <- fetch_account(account_id, subject) do
            {:ok, {:unchanged, account}}
          end

        {:error, :unauthorized} = error ->
          error
      end
    end

    defp transition_account_deletion(_account, _attrs, _action, _subject), do: {:error, :unauthorized}

    defp maybe_insert_delete_job({:transitioned, account}) do
      %{"account_id" => account.id}
      |> DeleteAccount.new(scheduled_at: account.scheduled_deletion_at)
      |> Oban.insert()
    end

    defp maybe_insert_delete_job({:unchanged, _account}), do: {:ok, nil}

    defp maybe_insert_reminder_job({:transitioned, account}) do
      reminder_at = DateTime.add(account.scheduled_deletion_at, -48, :hour)

      if DateTime.compare(reminder_at, DateTime.utc_now()) == :gt do
        %{"account_id" => account.id}
        |> AccountDeletionReminder.new(scheduled_at: reminder_at)
        |> Oban.insert()
      else
        {:ok, nil}
      end
    end

    defp maybe_insert_reminder_job({:unchanged, _account}), do: {:ok, nil}

    defp maybe_cancel_delete_jobs({:transitioned, account}) do
      cancel_delete_jobs(account.id)
    end

    defp maybe_cancel_delete_jobs({:unchanged, _account}), do: {:ok, []}

    defp cancel_delete_jobs(account_id) do
      [worker: DeleteAccount, state: [:scheduled, :available, :retryable]]
      |> Oban.Job.query()
      |> where([j], fragment("?->>'account_id'", j.args) == ^account_id)
      |> Oban.cancel_all_jobs()
    end

    defp maybe_cancel_reminder_jobs({:transitioned, account}) do
      cancel_reminder_jobs(account.id)
    end

    defp maybe_cancel_reminder_jobs({:unchanged, _account}), do: {:ok, []}

    defp cancel_reminder_jobs(account_id) do
      [worker: AccountDeletionReminder, state: [:scheduled, :available, :retryable]]
      |> Oban.Job.query()
      |> where([j], fragment("?->>'account_id'", j.args) == ^account_id)
      |> Oban.cancel_all_jobs()
    end

    def get_account_admin_emails(account_id, subject) do
      from(a in Actor,
        where: a.account_id == ^account_id,
        where: a.type == :account_admin_user,
        where: is_nil(a.disabled_at),
        select: a.email
      )
      |> Safe.scoped(subject)
      |> Safe.all()
    end

    defp restrict_to_matching_transition(query, :schedule) do
      where(query, [a], is_nil(a.scheduled_deletion_at))
    end

    defp restrict_to_matching_transition(query, :cancel) do
      where(query, [a], not is_nil(a.scheduled_deletion_at))
    end
  end
end
