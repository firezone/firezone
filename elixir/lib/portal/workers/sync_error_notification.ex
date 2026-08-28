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
    unique: [period: :infinity, states: :incomplete]

  alias Portal.Billing
  alias Portal.Defender
  alias Portal.Entra
  alias Portal.Google
  alias Portal.Intune
  alias Portal.Iru
  alias Portal.Santa
  alias Portal.SentinelOne
  alias Portal.Okta
  alias Portal.Mailer
  alias __MODULE__.Database
  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"provider" => provider} = args}) do
    case provider do
      "entra" -> check_entra_directories(args)
      "google" -> check_google_directories(args)
      "okta" -> check_okta_directories(args)
      "intune" -> check_intune_providers(args)
      "iru" -> check_iru_providers(args)
      "defender" -> check_defender_providers(args)
      "santa" -> check_santa_providers(args)
      "sentinelone" -> check_sentinelone_providers(args)
      _ -> {:error, "Unknown provider: #{provider}"}
    end
  end

  defp check_entra_directories(%{"frequency" => frequency}) do
    Entra.Directory
    |> Database.errored_disabled_directories(frequency)
    |> Enum.each(&send_notification(:entra, &1, frequency))

    :ok
  end

  defp check_google_directories(%{"frequency" => frequency}) do
    Google.Directory
    |> Database.errored_disabled_directories(frequency)
    |> Enum.each(&send_notification(:google, &1, frequency))

    :ok
  end

  defp check_okta_directories(%{"frequency" => frequency}) do
    Okta.Directory
    |> Database.errored_disabled_directories(frequency)
    |> Enum.each(&send_notification(:okta, &1, frequency))

    :ok
  end

  # A posture provider carries the same error columns as a directory, so
  # the shared query and escalation schedule apply unchanged. An account that
  # loses device posture stops syncing, so chasing its admins about an error they
  # can no longer act on would be noise.
  defp check_intune_providers(%{"frequency" => frequency}) do
    Intune.PostureProvider
    |> Database.errored_disabled_providers(frequency)
    |> Enum.filter(&Portal.Account.device_posture_enabled?(&1.account))
    |> Enum.each(&send_notification(:intune, &1, frequency))

    :ok
  end

  defp check_iru_providers(%{"frequency" => frequency}) do
    Iru.PostureProvider
    |> Database.errored_disabled_providers(frequency)
    |> Enum.filter(&Portal.Account.device_posture_enabled?(&1.account))
    |> Enum.each(&send_notification(:iru, &1, frequency))

    :ok
  end

  defp check_defender_providers(%{"frequency" => frequency}) do
    Defender.PostureProvider
    |> Database.errored_disabled_providers(frequency)
    |> Enum.filter(&Portal.Account.device_posture_enabled?(&1.account))
    |> Enum.each(&send_notification(:defender, &1, frequency))

    :ok
  end

  defp check_santa_providers(%{"frequency" => frequency}) do
    Santa.PostureProvider
    |> Database.errored_disabled_providers(frequency)
    |> Enum.filter(&Portal.Account.device_posture_enabled?(&1.account))
    |> Enum.each(&send_notification(:santa, &1, frequency))

    :ok
  end

  defp check_sentinelone_providers(%{"frequency" => frequency}) do
    SentinelOne.PostureProvider
    |> Database.errored_disabled_providers(frequency)
    |> Enum.filter(&Portal.Account.device_posture_enabled?(&1.account))
    |> Enum.each(&send_notification(:sentinelone, &1, frequency))

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
    admins = Database.get_account_admin_actors(directory.account_id)

    cond do
      admins == [] ->
        Logger.error("No admin actors found for account",
          account_id: directory.account_id,
          directory_id: directory.id
        )

      # Leave the count alone so a returning account still gets the full series.
      dormant?(directory.account) ->
        Logger.info("Skipping sync error notification for dormant account",
          account_id: directory.account_id,
          directory_id: directory.id
        )

      true ->
        increment_error_email_count(directory)
        send_email_notification(provider, admins, directory, frequency)
    end
  end

  defp dormant?(account) do
    not Billing.paid_plan?(account) and not Database.account_active?(account.id)
  end

  defp send_email_notification(provider, admins, directory, frequency) do
    recipient_emails = Enum.map(admins, & &1.email)

    Logger.info("Sending sync error email",
      recipient_count: length(recipient_emails),
      directory_id: directory.id,
      directory_name: directory.name,
      frequency: frequency
    )

    # Attempt to send the email but log errors if it fails. Important not to raise here
    # otherwise we won't increment the error email count and potentially spam admins with emails.
    error_email(provider, directory, recipient_emails)
    |> mailer_module().enqueue()
    |> case do
      {:ok, _result} ->
        Logger.info("Sync error email enqueued successfully",
          recipient_count: length(recipient_emails),
          directory_id: directory.id
        )

      {:error, reason} ->
        Logger.error("Failed to enqueue sync error email",
          recipient_count: length(recipient_emails),
          reason: inspect(reason),
          directory_id: directory.id
        )
    end
  end

  defp error_email(provider_type, provider, recipients)
       when provider_type in [:intune, :iru, :defender, :santa, :sentinelone],
    do: sync_email_module().posture_provider_error_email(provider, recipients)

  defp error_email(provider, directory, recipients) when provider in [:entra, :google, :okta],
    do: sync_email_module().sync_error_email(directory, recipients)

  defp mailer_module do
    Portal.Config.get_env(:portal, __MODULE__, [])
    |> Keyword.get(:mailer_module, Mailer)
  end

  defp sync_email_module do
    Portal.Config.get_env(:portal, __MODULE__, [])
    |> Keyword.get(:sync_email_module, Mailer.SyncEmail)
  end

  defp increment_error_email_count(directory) do
    new_count = directory.error_email_count + 1

    {:ok, _directory} =
      directory
      |> Ecto.Changeset.cast(%{"error_email_count" => new_count}, [:error_email_count])
      |> Database.update_directory()
  end

  defmodule Database do
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

    # A posture provider keeps its name on the shared posture_providers row, and
    # the notification names the provider it is about.
    def errored_disabled_providers(schema, frequency) do
      schema
      |> errored_disabled_directories_query(frequency)
      |> Ecto.Query.preload(:posture_provider)
      |> Safe.unscoped()
      |> Safe.all()
      |> Enum.map(&%{&1 | name: &1.posture_provider.name})
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
        where: a.is_disabled == false
      )
      |> Safe.unscoped()
      |> Safe.all()
    end

    def account_active?(account_id) do
      from(sl in Portal.SessionLog, where: sl.account_id == ^account_id)
      |> Safe.unscoped()
      |> Safe.exists?()
    end
  end
end
