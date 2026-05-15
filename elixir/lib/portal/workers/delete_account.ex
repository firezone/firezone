defmodule Portal.Workers.DeleteAccount do
  @moduledoc """
  Oban worker that hard-deletes a single account once its scheduled deletion time is due.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [
      period: :infinity,
      states: [:available, :scheduled, :executing, :retryable],
      keys: [:account_id]
  ]

  alias Portal.Account
  alias Portal.Billing
  alias Portal.Mailer
  alias Portal.Mailer.Notifications
  alias __MODULE__.Database
  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"account_id" => account_id}}) do
    case Database.fetch_account(account_id) do
      nil ->
        :ok

      %Account{} = account ->
        maybe_delete_account(account)
    end
  end

  defp maybe_delete_account(%Account{} = account) do
    cond do
      is_nil(account.scheduled_deletion_at) ->
        :ok

      is_nil(account.disabled_at) ->
        :ok

      DateTime.compare(account.scheduled_deletion_at, DateTime.utc_now()) == :gt ->
        {:snooze, DateTime.diff(account.scheduled_deletion_at, DateTime.utc_now())}

      true ->
        Logger.info("Hard-deleting account pending deletion", account_id: account.id)

        delete_account_and_notify_admins(account)
    end
  end

  defp delete_account_and_notify_admins(%Account{} = account) do
    with :ok <- Billing.cancel_subscriptions(account) do
      admin_emails = Database.get_account_admin_emails(account.id)

      if admin_emails == [] do
        Logger.warning("No admin actors found for account deletion completion notification",
          account_id: account.id
        )
      end

      account
      |> Database.delete_account()
      |> maybe_enqueue_email(admin_emails)
    end
  end

  defp maybe_enqueue_email({:ok, _account}, []), do: :ok

  defp maybe_enqueue_email({:ok, account}, admin_emails) do
    email = Notifications.account_deletion_completed_email(account, admin_emails)

    case Mailer.enqueue(email) do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logger.error("Failed to enqueue account deletion notification email",
          account_id: account.id,
          account_slug: account.slug,
          reason: inspect(reason)
        )

        :ok
    end
  end

  defp maybe_enqueue_email({:error, _} = err, _), do: err

  defmodule Database do
    import Ecto.Query

    alias Portal.Account
    alias Portal.Actor
    alias Portal.Safe

    def fetch_account(account_id) do
      from(a in Account, where: a.id == ^account_id)
      |> Safe.unscoped()
      |> Safe.one()
    end

    def get_account_admin_emails(account_id) do
      from(a in Actor,
        where: a.account_id == ^account_id,
        where: a.type == :account_admin_user,
        where: is_nil(a.disabled_at),
        select: a.email
      )
      |> Safe.unscoped()
      |> Safe.all()
    end

    def delete_account(%Account{} = account) do
      account
      |> Safe.unscoped()
      |> Safe.delete()
    end
  end
end
