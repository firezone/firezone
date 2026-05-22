defmodule Portal.Workers.AccountDeletionReminder do
  @moduledoc """
  Oban worker that sends a 48-hour pre-deletion reminder email to account admins.
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
  alias Portal.Mailer
  alias Portal.Mailer.Notifications
  alias __MODULE__.Database
  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"account_id" => account_id}}) do
    case Database.fetch_account(account_id) do
      nil ->
        :ok

      %Account{scheduled_deletion_at: nil} ->
        :ok

      %Account{} = account ->
        notify_admins(account)
    end
  end

  defp notify_admins(%Account{} = account) do
    admin_emails = Database.get_account_admin_emails(account.id)

    case admin_emails do
      [] ->
        Logger.warning("No admin actors found for account deletion reminder notification",
          account_id: account.id
        )

        :ok

      admin_emails ->
        email = Notifications.account_deletion_reminder_email(account, admin_emails)

        case Mailer.enqueue(email) do
          {:ok, _job} ->
            :ok

          {:error, reason} ->
            Logger.error("Failed to enqueue account deletion reminder email",
              account_id: account.id,
              reason: inspect(reason)
            )

            :ok
        end
    end
  end

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
  end
end
