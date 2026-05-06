defmodule Portal.Accounts.Deletion do
  @moduledoc false

  alias Portal.Account
  alias Portal.Mailer
  alias Portal.Mailer.Notifications
  alias Portal.Safe
  alias Portal.Workers.DeleteAccount
  alias __MODULE__.Database
  require Logger

  def schedule_account_deletion(%Account{} = account, attrs, subject) do
    Database.transact(fn ->
      with {:ok, account} <- Database.fetch_account(account.id, subject),
           {:ok, transition} <- Database.transition_account_deletion(account, attrs, :schedule),
           {:ok, _job} <- maybe_insert_delete_job(transition) do
        {:ok, transition}
      end
    end)
    |> case do
      {:ok, {:transitioned, account}} ->
        maybe_enqueue_account_deletion_notification(account, subject, :schedule)

      {:ok, {:unchanged, account}} ->
        {:ok, account}

      {:error, :unauthorized} ->
        {:error, :unauthorized}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def cancel_account_deletion(%Account{} = account, subject) do
    Database.transact(fn ->
      with {:ok, account} <- Database.fetch_account(account.id, subject),
           {:ok, transition} <-
             Database.transition_account_deletion(
               account,
               %{disabled_at: nil, scheduled_deletion_at: nil},
               :cancel
             ),
           {:ok, _jobs} <- maybe_cancel_delete_jobs(transition) do
        {:ok, transition}
      end
    end)
    |> case do
      {:ok, {:transitioned, account}} ->
        maybe_enqueue_account_deletion_notification(account, subject, :cancel)

      {:ok, {:unchanged, account}} ->
        {:ok, account}

      {:error, :unauthorized} ->
        {:error, :unauthorized}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_insert_delete_job({:transitioned, account}) do
    %{"account_id" => account.id}
    |> DeleteAccount.new(scheduled_at: account.scheduled_deletion_at)
    |> Oban.insert()
  end

  defp maybe_insert_delete_job({:unchanged, _account}), do: {:ok, nil}

  defp maybe_cancel_delete_jobs({:transitioned, account}) do
    Database.cancel_delete_jobs(account.id)
  end

  defp maybe_cancel_delete_jobs({:unchanged, _account}), do: {:ok, []}

  defp maybe_enqueue_account_deletion_notification(%Account{} = account, subject, action) do
    admin_emails = Database.get_account_admin_emails(account.id, subject)

    case admin_emails do
      [] ->
        Logger.warning("No admin actors found for account deletion notification",
          account_id: account.id,
          action: action
        )

        {:ok, account}

      admin_emails ->
        account
        |> account_deletion_notification_email(admin_emails, action)
        |> Mailer.enqueue()
        |> case do
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
  end

  defp account_deletion_notification_email(account, admin_emails, :schedule) do
    Notifications.account_scheduled_for_deletion_email(account, admin_emails)
  end

  defp account_deletion_notification_email(account, admin_emails, :cancel) do
    Notifications.account_deletion_aborted_email(account, admin_emails)
  end

  defmodule Database do
    import Ecto.Query

    alias Oban.Job
    alias Portal.Account
    alias Portal.Actor
    alias Portal.Safe

    def fetch_account(account_id, subject) do
      from(a in Account, where: a.id == ^account_id)
      |> Safe.scoped(subject)
      |> Safe.one()
      |> case do
        %Account{} = account -> {:ok, account}
        nil -> {:error, :unauthorized}
        {:error, :unauthorized} = error -> error
      end
    end

    def transact(multi) do
      Safe.transact(multi)
    end

    def transition_account_deletion(%Account{} = account, attrs, action) do
      now = DateTime.utc_now()

      query =
        from(a in Account,
          where: a.id == ^account.id,
          select: a
        )
        |> restrict_to_matching_transition(action)

      updates =
        attrs
        |> Map.take([:disabled_at, :scheduled_deletion_at])
        |> Map.put(:updated_at, now)

      case query |> Safe.unscoped() |> Safe.update_all(set: Map.to_list(updates)) do
        {1, [updated_account]} ->
          {:ok, {:transitioned, updated_account}}

        {0, _} ->
          {:ok, {:unchanged, fetch_account_unscoped!(account.id)}}
      end
    end

    def cancel_delete_jobs(account_id) do
      query =
        from(j in Job,
          where: j.worker == "Portal.Workers.DeleteAccount",
          where: j.state in ["scheduled", "available", "retryable"],
          where: fragment("?->>'account_id' = ?", j.args, ^account_id)
        )

      Oban.cancel_all_jobs(query)
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

    def fetch_account_unscoped(account_id) do
      from(a in Account, where: a.id == ^account_id)
      |> Safe.unscoped()
      |> Safe.one()
    end

    def fetch_account_unscoped!(account_id) do
      from(a in Account, where: a.id == ^account_id)
      |> Safe.unscoped()
      |> Safe.one!()
    end

    def delete_account(%Account{} = account) do
      account
      |> Safe.unscoped()
      |> Safe.delete()
    end

    defp restrict_to_matching_transition(query, :schedule) do
      where(query, [a], is_nil(a.scheduled_deletion_at))
    end

    defp restrict_to_matching_transition(query, :cancel) do
      where(query, [a], not is_nil(a.scheduled_deletion_at))
    end
  end
end
