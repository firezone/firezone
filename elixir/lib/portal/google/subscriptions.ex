defmodule Portal.Google.Subscriptions do
  @moduledoc """
  Oban worker that keeps the Google Directory API `users.watch` channel for
  one Google directory alive.

  Google caps a channel at 6 hours and cannot renew one, so this job replaces
  the channel shortly before it expires and schedules itself to run again
  before the new one does. The directory's `webhook_secret` rides along as the
  channel token so notifications can be authenticated.
  """

  use Oban.Worker, queue: :google_subscriptions, max_attempts: 3

  alias Portal.Google
  alias Portal.Google.APIClient
  alias __MODULE__.Database
  require Logger

  @lifetime_seconds 6 * 60 * 60
  @renew_within_seconds 30 * 60
  @min_schedule_seconds 60
  @retry_seconds 10 * 60

  # A scheduled "renew" must not swallow an immediate "ensure", so the two keep
  # separate actions. :executing is left out so a job that arrives while one is
  # running still queues.
  @unique [
    period: :infinity,
    states: [:available, :scheduled, :retryable],
    keys: [:directory_id, :action]
  ]

  @impl Oban.Worker
  def new(args, opts), do: super(args, Keyword.put_new(opts, :unique, @unique))

  @impl Oban.Worker
  def perform(%Oban.Job{
        args:
          %{
            "action" => "stop",
            "account_id" => account_id,
            "directory_id" => directory_id,
            "channel_id" => channel_id,
            "resource_id" => resource_id
          } = args
      }) do
    with {:ok, access_token} <- stop_access_token(account_id, directory_id, args),
         :ok <- stop_channel(access_token, channel_id, resource_id) do
      Database.clear_channel(account_id, directory_id, channel_id)
      :ok
    end
  end

  def perform(%Oban.Job{
        args: %{"account_id" => account_id, "directory_id" => directory_id, "action" => action}
      })
      when action in ["ensure", "renew"] do
    case Database.get_directory(account_id, directory_id) do
      nil ->
        Logger.info("Google directory not eligible for webhooks, skipping",
          google_directory_id: directory_id
        )

        :ok

      directory ->
        ensure(directory)
    end
  end

  def perform(_), do: :ok

  @doc """
  Fetches a directory that is enabled, verified, and on an account with the
  `idp_sync` feature. Nil otherwise.
  """
  def get_directory(account_id, directory_id), do: Database.get_directory(account_id, directory_id)

  @doc """
  Returns the URL Google posts user notifications to.
  """
  def notification_url(directory_id) do
    base =
      (Portal.Config.get_env(:portal, :rest_api_url) ||
         Portal.Config.fetch_env!(:portal, :api_external_url))
      |> String.trim_trailing("/")

    "#{base}/integrations/google/webhooks?directory_id=#{directory_id}"
  end

  # A channel lives six hours, so a failed replacement is retried until the
  # directory stops being eligible rather than discarded after a few attempts.
  defp ensure(directory) do
    if needs_attention?(directory) do
      case replace_channel(directory) do
        {:ok, directory} ->
          schedule_renewal(directory)

        {:error, reason} ->
          Logger.warning("Failed to open Google users watch channel, retrying",
            google_directory_id: directory.id,
            reason: inspect(reason)
          )

          {:snooze, @retry_seconds}
      end
    else
      schedule_renewal(directory)
    end
  end

  defp needs_attention?(directory) do
    renew_by = DateTime.utc_now() |> DateTime.add(@renew_within_seconds, :second)

    is_nil(directory.users_channel_id) or is_nil(directory.users_resource_id) or
      is_nil(directory.channel_expires_at) or
      DateTime.compare(directory.channel_expires_at, renew_by) == :lt
  end

  defp replace_channel(directory) do
    access_token = Google.Sync.get_access_token!(directory)
    directory = ensure_secret(directory)
    previous = {directory.users_channel_id, directory.users_resource_id}
    requested_expires_at = DateTime.utc_now() |> DateTime.add(@lifetime_seconds, :second)

    channel = %{
      "id" => Ecto.UUID.generate(),
      "type" => "web_hook",
      "address" => notification_url(directory.id),
      "token" => directory.webhook_secret,
      "expiration" => DateTime.to_unix(requested_expires_at, :millisecond)
    }

    case APIClient.watch_users(access_token, channel) do
      {:ok, %Req.Response{status: 200, body: %{"id" => id, "resourceId" => resource_id} = body}}
      when is_binary(id) and is_binary(resource_id) ->
        expires_at = expiration(body["expiration"], requested_expires_at)

        {:ok, directory} =
          Database.update_directory(directory, %{
            users_channel_id: id,
            users_resource_id: resource_id,
            channel_expires_at: expires_at
          })

        stop_previous_channel(directory, access_token, previous)

        Logger.info("Google users watch channel active",
          google_directory_id: directory.id,
          expires_at: expires_at
        )

        {:ok, directory}

      other ->
        {:error, {:watch_users, other}}
    end
  end

  # Google reports the expiration it actually applied as a millisecond string.
  defp expiration(value, fallback) when is_binary(value) do
    case Integer.parse(value) do
      {ms, ""} -> DateTime.from_unix!(ms, :millisecond)
      _ -> fallback
    end
  end

  defp expiration(value, _fallback) when is_integer(value),
    do: DateTime.from_unix!(value, :millisecond)

  defp expiration(_value, fallback), do: fallback

  defp stop_previous_channel(_directory, _access_token, {nil, _resource_id}), do: :ok

  defp stop_previous_channel(directory, access_token, {channel_id, resource_id}) do
    case stop_channel(access_token, channel_id, resource_id) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.info("Failed to stop replaced Google users watch channel",
          google_directory_id: directory.id,
          channel_id: channel_id,
          reason: inspect(reason)
        )
    end
  end

  defp schedule_renewal(directory) do
    delay =
      directory.channel_expires_at
      |> DateTime.diff(DateTime.utc_now(), :second)
      |> Kernel.-(@renew_within_seconds)
      |> max(@min_schedule_seconds)

    {:ok, _job} =
      %{account_id: directory.account_id, directory_id: directory.id, action: "renew"}
      |> new(schedule_in: delay)
      |> Oban.insert()

    :ok
  end

  defp ensure_secret(%{webhook_secret: nil} = directory) do
    secret = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
    {:ok, directory} = Database.update_directory(directory, %{webhook_secret: secret})
    directory
  end

  defp ensure_secret(directory), do: directory

  defp stop_channel(access_token, channel_id, resource_id) do
    case APIClient.stop_channel(access_token, channel_id, resource_id) do
      {:ok, %Req.Response{status: status}} when status in [200, 204, 404] -> :ok
      {:ok, response} -> {:error, {:stop_channel, response}}
      {:error, reason} -> {:error, {:stop_channel, reason}}
    end
  end

  # The channel was opened as the admin the job names, who may differ from the
  # one now on the row, and the row itself is gone once the directory is
  # deleted. Only a legacy key still comes from the row.
  defp stop_access_token(account_id, directory_id, args) do
    directory = Database.get_any_directory(account_id, directory_id)
    email = args["impersonation_email"] || (directory && directory.impersonation_email)

    case directory do
      %{legacy_service_account_key: key} when is_map(key) and map_size(key) > 0 ->
        APIClient.get_access_token(email, key)

      _ ->
        APIClient.get_access_token(email)
    end
  end

  defmodule Database do
    import Ecto.Query
    alias Portal.Safe

    def get_directory(account_id, id) do
      from(d in Portal.Google.Directory,
        join: a in Portal.Account,
        on: a.id == d.account_id,
        where: d.account_id == ^account_id,
        where: d.id == ^id,
        where: d.is_disabled == false,
        where: d.is_verified == true,
        where: a.is_disabled == false,
        where: fragment("(?)->>'idp_sync' = 'true'", a.features)
      )
      |> Safe.unscoped()
      |> Safe.one()
    end

    def get_any_directory(account_id, id) do
      from(d in Portal.Google.Directory,
        where: d.account_id == ^account_id,
        where: d.id == ^id
      )
      |> Safe.unscoped()
      |> Safe.one()
    end

    def clear_channel(account_id, directory_id, channel_id) do
      from(d in Portal.Google.Directory,
        where: d.account_id == ^account_id,
        where: d.id == ^directory_id,
        where: d.users_channel_id == ^channel_id
      )
      |> Safe.unscoped()
      |> Safe.update_all(
        set: [users_channel_id: nil, users_resource_id: nil, channel_expires_at: nil]
      )

      :ok
    end

    def update_directory(directory, attrs) do
      directory
      |> Ecto.Changeset.cast(attrs, [
        :webhook_secret,
        :users_channel_id,
        :users_resource_id,
        :channel_expires_at
      ])
      |> Portal.Google.Directory.changeset()
      |> Safe.unscoped()
      |> Safe.update()
    end
  end
end
