defmodule Portal.Accounts.Deletion do
  @moduledoc false

  alias Ecto.Multi
  alias Portal.Account
  alias Portal.Mailer
  alias Portal.Mailer.Notifications
  alias Portal.Safe
  alias Portal.Workers.DeleteAccount
  alias __MODULE__.Database
  require Logger

  def schedule_account_deletion(%Account{} = account, attrs, subject) do
    Multi.new()
    |> Multi.run(:account, fn _repo, _changes -> Database.fetch_account(account.id, subject) end)
    |> Multi.run(:transition, fn _repo, %{account: account} ->
      Database.transition_account_deletion(account, attrs, :schedule)
    end)
    |> Multi.merge(fn %{transition: transition} ->
      case transition do
        {:transitioned, account} ->
          Multi.new()
          |> Oban.insert(
            :delete_job,
            DeleteAccount.new(%{"account_id" => account.id},
              scheduled_at: account.scheduled_deletion_at
            )
          )

        {:unchanged, _account} ->
          Multi.new()
      end
    end)
    |> Database.transact()
    |> case do
      {:ok, %{transition: {:transitioned, account}}} ->
        maybe_enqueue_account_deletion_notification(account, subject, :schedule)

      {:ok, %{transition: {:unchanged, account}}} ->
        {:ok, account}

      {:error, :account, :unauthorized, _changes} ->
        {:error, :unauthorized}

      {:error, :transition, :unauthorized, _changes} ->
        {:error, :unauthorized}

      {:error, _step, reason, _changes} ->
        {:error, reason}
    end
  end

  def cancel_account_deletion(%Account{} = account, subject) do
    Multi.new()
    |> Multi.run(:account, fn _repo, _changes -> Database.fetch_account(account.id, subject) end)
    |> Multi.run(:transition, fn _repo, %{account: account} ->
      Database.transition_account_deletion(
        account,
        %{disabled_at: nil, scheduled_deletion_at: nil},
        :cancel
      )
    end)
    |> Multi.run(:cancel_delete_jobs, fn _repo, %{transition: transition} ->
      case transition do
        {:transitioned, account} -> Database.cancel_delete_jobs(account.id)
        {:unchanged, _account} -> {:ok, []}
      end
    end)
    |> Database.transact()
    |> case do
      {:ok, %{transition: {:transitioned, account}}} ->
        maybe_enqueue_account_deletion_notification(account, subject, :cancel)

      {:ok, %{transition: {:unchanged, account}}} ->
        {:ok, account}

      {:error, :account, :unauthorized, _changes} ->
        {:error, :unauthorized}

      {:error, :transition, :unauthorized, _changes} ->
        {:error, :unauthorized}

      {:error, _step, reason, _changes} ->
        {:error, reason}
    end
  end

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
