defmodule Portal.Workers.AccountDeletionCompleted do
  @moduledoc """
  Oban worker that delivers the account deletion completion email to admin recipients.
  Enqueued by DeleteAccount after the account row is deleted.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 3

  alias Portal.Account
  alias Portal.Mailer
  alias Portal.Mailer.Notifications
  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"admin_emails" => []}}), do: :ok

  def perform(%Oban.Job{
        args: %{
          "account_id" => account_id,
          "account_slug" => account_slug,
          "admin_emails" => admin_emails
        }
      }) do
    account = %Account{id: account_id, slug: account_slug}

    account
    |> Notifications.account_deletion_completed_email(admin_emails)
    |> Mailer.deliver()
    |> case do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.error("Failed to deliver account deletion completion email",
          account_id: account_id,
          account_slug: account_slug,
          reason: inspect(reason)
        )

        {:error, reason}
    end
  end
end
