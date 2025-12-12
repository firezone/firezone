defmodule Domain.Workers.SyncErrorNotification do
  @moduledoc """
  Oban workers for sending directory sync error notifications.

  Three notification frequencies based on error_email_count:
  - Daily: error_email_count < 3 (0, 1, 2)
  - Every 3 days: error_email_count 3-6
  - Weekly: error_email_count 7-10

  After 10 failed notifications, stop sending emails.
  """

  use Oban.Worker,
    queue: :sync_error_notifications,
    max_attempts: 3,
    unique: [period: :infinity, states: [:available, :scheduled, :executing, :retryable]]

  alias Domain.{Entra, Google, Mailer}
  alias __MODULE__.DB
  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"provider" => provider} = args}) do
    case provider do
      "entra" -> check_entra_directories(args)
      "google" -> check_google_directories(args)
      _ -> {:error, "Unknown provider: #{provider}"}
    end
  end

  defp check_entra_directories(%{"frequency" => frequency}) do
    Entra.Directory
    |> DB.errored_directories(frequency)
    |> Enum.each(&send_notification(:entra, &1, frequency))

    :ok
  end

  defp check_google_directories(%{"frequency" => frequency}) do
    Google.Directory
    |> DB.errored_directories(frequency)
    |> Enum.each(&send_notification(:google, &1, frequency))

    :ok
  end

  defp send_notification(provider, directory, frequency) do
    Logger.info("Sending sync error notification",
      provider: provider,
      directory_id: directory.id,
      account_id: directory.account_id,
      frequency: frequency,
      error_email_count: directory.error_email_count
    )

    # Get account admin actors and send notifications
    admins = DB.get_account_admin_actors(directory.account_id)

    case admins do
      [] ->
        Logger.warning("No admin actors found for account",
          account_id: directory.account_id,
          directory_id: directory.id
        )

      admins ->
        Enum.each(admins, fn admin ->
          send_email_notification(admin, directory, frequency)
        end)
    end

    # Increment error email count
    increment_error_email_count(provider, directory)
  end

  defp send_email_notification(admin, directory, frequency) do
    Logger.info("Sending sync error email",
      to: admin.email,
      directory_id: directory.id,
      directory_name: directory.name,
      frequency: frequency
    )

    # Send the actual email using the existing mailer module
    Mailer.SyncEmail.sync_error_email(directory, admin.email)
    |> Mailer.deliver()
  end

  defp increment_error_email_count(provider, directory) do
    DB.increment_error_email_count(provider, directory)
  end

  defmodule DB do
    import Ecto.Query
    alias Domain.Safe

    def errored_directories(schema, frequency) do
      schema
      |> errored_directories_query(frequency)
      |> Safe.unscoped()
      |> Safe.all()
    end

    defp errored_directories_query(schema, "daily") do
      from(d in schema,
        where: not is_nil(d.errored_at),
        where: d.error_email_count < 3,
        preload: [:account]
      )
    end

    defp errored_directories_query(schema, "three_days") do
      from(d in schema,
        where: not is_nil(d.errored_at),
        where: d.error_email_count >= 3,
        where: d.error_email_count <= 6,
        preload: [:account]
      )
    end

    defp errored_directories_query(schema, "weekly") do
      from(d in schema,
        where: not is_nil(d.errored_at),
        where: d.error_email_count >= 7,
        where: d.error_email_count < 10,
        preload: [:account]
      )
    end

    def increment_error_email_count(:entra, directory) do
      new_count = (directory.error_email_count || 0) + 1

      changeset =
        Ecto.Changeset.cast(directory, %{"error_email_count" => new_count}, [:error_email_count])

      {:ok, _directory} = changeset |> Safe.unscoped() |> Safe.update()
    end

    def increment_error_email_count(:google, directory) do
      new_count = (directory.error_email_count || 0) + 1

      changeset =
        Ecto.Changeset.cast(directory, %{"error_email_count" => new_count}, [:error_email_count])

      {:ok, _directory} = changeset |> Safe.unscoped() |> Safe.update()
    end

    def get_account_admin_actors(account_id) do
      from(a in Domain.Actor,
        where: a.account_id == ^account_id,
        where: a.type == :account_admin_user,
        where: is_nil(a.disabled_at)
      )
      |> Safe.unscoped()
      |> Safe.all()
    end
  end
end
