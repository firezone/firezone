defmodule Portal.Workers.SyncErrorNotification do
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

  alias Portal.Entra
  alias Portal.Google
  alias Portal.Okta
  alias Portal.Mailer
  alias __MODULE__.DB
  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"provider" => provider} = args}) do
    case provider do
      "entra" -> check_entra_directories(args)
      "google" -> check_google_directories(args)
      "okta" -> check_okta_directories(args)
      _ -> {:error, "Unknown provider: #{provider}"}
    end
  end

  defp check_entra_directories(%{"frequency" => frequency}) do
    Entra.Directory
    |> DB.errored_disabled_directories(frequency)
    |> Enum.each(&send_notification(:entra, &1, frequency))

    :ok
  end

  defp check_google_directories(%{"frequency" => frequency}) do
    Google.Directory
    |> DB.errored_disabled_directories(frequency)
    |> Enum.each(&send_notification(:google, &1, frequency))

    :ok
  end

  defp check_okta_directories(%{"frequency" => frequency}) do
    Okta.Directory
    |> DB.errored_disabled_directories(frequency)
    |> Enum.each(&send_notification(:okta, &1, frequency))

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
        Logger.error("No admin actors found for account",
          account_id: directory.account_id,
          directory_id: directory.id
        )

      admins ->
        increment_error_email_count(directory)

        Enum.each(admins, fn admin ->
          send_email_notification(admin, directory, frequency)
        end)
    end
  end

  defp send_email_notification(admin, directory, frequency) do
    Logger.info("Sending sync error email",
      to: admin.email,
      directory_id: directory.id,
      directory_name: directory.name,
      frequency: frequency
    )

    # Attempt to send the email but log errors if it fails. Important not to raise here
    # otherwise we won't increment the error email count and potentially spam admins with emails.
    Mailer.SyncEmail.sync_error_email(directory, admin.email)
    |> Mailer.deliver()
    |> case do
      {:ok, _result} ->
        Logger.info("Sync error email sent successfully",
          to: admin.email,
          directory_id: directory.id
        )

      {:error, reason} ->
        Logger.error("Failed to send sync error email",
          to: admin.email,
          reason: reason,
          directory_id: directory.id
        )
    end
  end

  defp increment_error_email_count(directory) do
    new_count = directory.error_email_count + 1

    {:ok, _directory} =
      directory
      |> Ecto.Changeset.cast(%{"error_email_count" => new_count}, [:error_email_count])
      |> DB.update_directory()
  end

  defmodule DB do
    import Ecto.Query
    alias Portal.Safe

    # We want to find all directories that are currently disabled due to sync errors.
    # For 4xx errors, the directory is disabled immediately.
    # For 5xx errors, the directory is disabled after 24 hours of continuous failures.
    # We only want to notify admins once a directory becomes disabled.
    def errored_disabled_directories(schema, frequency) do
      schema
      |> errored_disabled_directories_query(frequency)
      |> Safe.unscoped()
      |> Safe.all()
    end

    defp errored_disabled_directories_query(schema, "daily") do
      from(d in schema,
        where: not is_nil(d.errored_at),
        where: d.is_disabled == true,
        where: d.disabled_reason == "Sync error",
        where: d.error_email_count < 3,
        preload: [:account]
      )
    end

    defp errored_disabled_directories_query(schema, "three_days") do
      from(d in schema,
        where: not is_nil(d.errored_at),
        where: d.is_disabled == true,
        where: d.disabled_reason == "Sync error",
        where: d.error_email_count >= 3,
        where: d.error_email_count <= 6,
        preload: [:account]
      )
    end

    defp errored_disabled_directories_query(schema, "weekly") do
      from(d in schema,
        where: not is_nil(d.errored_at),
        where: d.is_disabled == true,
        where: d.disabled_reason == "Sync error",
        where: d.error_email_count >= 7,
        where: d.error_email_count < 10,
        preload: [:account]
      )
    end

    def update_directory(changeset) do
      changeset
      |> Safe.unscoped()
      |> Safe.update()
    end

    def get_account_admin_actors(account_id) do
      from(a in Portal.Actor,
        where: a.account_id == ^account_id,
        where: a.type == :account_admin_user,
        where: is_nil(a.disabled_at)
      )
      |> Safe.unscoped()
      |> Safe.all()
    end
  end
end
