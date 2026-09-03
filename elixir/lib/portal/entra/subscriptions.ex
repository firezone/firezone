defmodule Portal.Entra.Subscriptions do
  @moduledoc """
  Oban worker that keeps the Microsoft Graph change notification subscriptions
  for one Entra directory alive.

  One subscription covers `/users` and one covers `/groups`. Both share the
  directory's `webhook_secret` as their `clientState`, and both point at the
  Entra webhook endpoint with the directory id in the query string.
  """

  use Oban.Worker, queue: :entra_subscriptions, max_attempts: 3

  alias Portal.Entra
  alias Portal.Microsoft.Graph.APIClient
  alias __MODULE__.Database
  require Logger

  # Graph caps directory subscriptions at 41,760 minutes (under 29 days).
  @lifetime_days 28
  @renew_within_days 7
  @resources [users: "/users", groups: "/groups"]

  # Queued duplicates collapse into one job, but a notification that arrives
  # while a job is executing must still enqueue a fresh one, so :executing is
  # deliberately left out of the unique states.
  @unique [
    period: :infinity,
    states: [:available, :scheduled, :retryable],
    keys: [:directory_id, :action]
  ]

  @impl Oban.Worker
  def new(args, opts), do: super(args, Keyword.put_new(opts, :unique, @unique))

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{"action" => "delete", "tenant_id" => tenant_id, "subscription_ids" => ids}
      }) do
    case APIClient.get_access_token(:entra, tenant_id) do
      {:ok, %{body: %{"access_token" => access_token}}} ->
        Enum.each(ids, &delete_subscription(access_token, &1))

      other ->
        {:error, {:get_access_token, other}}
    end
  end

  def perform(
        %Oban.Job{
          args: %{"account_id" => account_id, "directory_id" => directory_id, "action" => action}
        } = job
      ) do
    case Database.get_directory(account_id, directory_id) do
      nil ->
        Logger.info("Entra directory not eligible for webhooks, skipping",
          entra_directory_id: directory_id
        )

        :ok

      directory ->
        directory
        |> forget_removed_subscription(action, job.args["subscription_id"])
        |> ensure(action == "renew")
    end
  end

  def perform(_), do: :ok

  @doc """
  Returns the URL Graph posts change and lifecycle notifications to.
  """
  def notification_url(directory_id) do
    base =
      (Portal.Config.get_env(:portal, :rest_api_url) ||
         Portal.Config.fetch_env!(:portal, :api_external_url))
      |> String.trim_trailing("/")

    "#{base}/integrations/entra/webhooks?directory_id=#{directory_id}"
  end

  defp forget_removed_subscription(directory, "recreate", subscription_id)
       when is_binary(subscription_id) do
    attrs =
      Enum.reduce([:users_subscription_id, :groups_subscription_id], %{}, fn field, acc ->
        if Map.fetch!(directory, field) == subscription_id do
          Map.put(acc, field, nil)
        else
          acc
        end
      end)

    {:ok, directory} = Database.update_directory(directory, attrs)
    directory
  end

  defp forget_removed_subscription(directory, _action, _subscription_id), do: directory

  defp ensure(directory, force?) do
    if force? or needs_attention?(directory) do
      access_token = Entra.Sync.get_access_token!(directory)
      directory = ensure_secret(directory)
      expires_at = DateTime.utc_now() |> DateTime.add(@lifetime_days, :day)

      with {:ok, users_id} <-
             ensure_subscription(directory, access_token, :users, expires_at),
           {:ok, groups_id} <-
             ensure_subscription(directory, access_token, :groups, expires_at),
           {:ok, _directory} <-
             Database.update_directory(directory, %{
               users_subscription_id: users_id,
               groups_subscription_id: groups_id,
               subscriptions_expire_at: expires_at
             }) do
        Logger.info("Entra webhook subscriptions active",
          entra_directory_id: directory.id,
          expires_at: expires_at
        )

        :ok
      end
    else
      :ok
    end
  end

  defp needs_attention?(directory) do
    renew_by = DateTime.utc_now() |> DateTime.add(@renew_within_days, :day)

    is_nil(directory.users_subscription_id) or is_nil(directory.groups_subscription_id) or
      is_nil(directory.subscriptions_expire_at) or
      DateTime.compare(directory.subscriptions_expire_at, renew_by) == :lt
  end

  defp ensure_secret(%{webhook_secret: nil} = directory) do
    secret = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
    {:ok, directory} = Database.update_directory(directory, %{webhook_secret: secret})
    directory
  end

  defp ensure_secret(directory), do: directory

  defp ensure_subscription(directory, access_token, resource, expires_at) do
    case Map.fetch!(directory, :"#{resource}_subscription_id") do
      nil ->
        create_subscription(directory, access_token, resource, expires_at)

      subscription_id ->
        case APIClient.renew_subscription(access_token, subscription_id, expires_at) do
          {:ok, %Req.Response{status: 200}} ->
            {:ok, subscription_id}

          {:ok, %Req.Response{status: 404}} ->
            create_subscription(directory, access_token, resource, expires_at)

          other ->
            {:error, {:renew_subscription, resource, other}}
        end
    end
  end

  defp delete_subscription(access_token, subscription_id) do
    case APIClient.delete_subscription(access_token, subscription_id) do
      {:ok, %Req.Response{status: status}} when status in [204, 404] ->
        :ok

      other ->
        Logger.warning("Failed to delete Entra subscription",
          subscription_id: subscription_id,
          reason: inspect(other)
        )
    end
  end

  defp create_subscription(directory, access_token, resource, expires_at) do
    url = notification_url(directory.id)

    attrs = %{
      "changeType" => "updated,deleted",
      "notificationUrl" => url,
      "lifecycleNotificationUrl" => url,
      "resource" => Keyword.fetch!(@resources, resource),
      "expirationDateTime" => DateTime.to_iso8601(expires_at),
      "clientState" => directory.webhook_secret
    }

    case APIClient.create_subscription(access_token, attrs) do
      {:ok, %Req.Response{status: 201, body: %{"id" => id}}} when is_binary(id) ->
        {:ok, id}

      other ->
        {:error, {:create_subscription, resource, other}}
    end
  end

  defmodule Database do
    import Ecto.Query
    alias Portal.Safe

    def get_directory(account_id, id) do
      from(d in Portal.Entra.Directory,
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

    def update_directory(directory, attrs) do
      directory
      |> Ecto.Changeset.cast(attrs, [
        :webhook_secret,
        :users_subscription_id,
        :groups_subscription_id,
        :subscriptions_expire_at
      ])
      |> Portal.Entra.Directory.changeset()
      |> Safe.unscoped()
      |> Safe.update()
    end
  end
end
