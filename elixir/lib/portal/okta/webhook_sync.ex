defmodule Portal.Okta.WebhookSync do
  @moduledoc """
  Oban worker that applies one Okta event to the identities, groups, and
  memberships of an Okta directory.

  An event names an object and nothing the worker trusts about it, so the
  worker re-reads the object from Okta and writes it with a fresh `synced_at`.
  Jobs for one directory run one at a time (see `Portal.DirectorySync`).

  A user is written when Okta still returns them, active, and assigned to at
  least one application, the way the full sync scopes users, and their
  memberships in the groups the directory tracks follow. Anything else about
  the user is removed. A group is written, created if need be, when Okta still
  returns it with at least one application assigned, and removed otherwise.
  """

  use Oban.Worker, queue: :okta_webhook, max_attempts: 3

  alias Portal.DirectorySync
  alias Portal.Okta
  alias Portal.Okta.APIClient
  alias __MODULE__.Database
  require Logger

  # Queued duplicates collapse into one job, but an event that arrives while a
  # job is executing must still enqueue a fresh one, so :executing is
  # deliberately left out of the unique states.
  @unique [
    period: :infinity,
    states: [:available, :scheduled, :retryable],
    keys: [:directory_id, :resource, :resource_id]
  ]

  @impl Oban.Worker
  def new(args, opts), do: super(args, Keyword.put_new(opts, :unique, @unique))

  @impl Oban.Worker
  def timeout(_job), do: DirectorySync.webhook_timeout()

  @impl Oban.Worker
  def perform(
        %Oban.Job{
          args: %{
            "account_id" => account_id,
            "directory_id" => directory_id,
            "resource" => resource,
            "resource_id" => resource_id
          }
        } = job
      ) do
    case Okta.Sync.get_directory(account_id, directory_id) do
      nil ->
        Logger.info("Okta directory not found or disabled, skipping event",
          okta_directory_id: directory_id
        )

        :ok

      directory ->
        DirectorySync.run_alone(:okta, directory.id, job, fn ->
          apply_change(directory, resource, resource_id)
        end)
    end
  end

  def perform(_), do: :ok

  defp apply_change(directory, "user", user_id) do
    Logger.info("Applying Okta user event", okta_directory_id: directory.id, user_id: user_id)
    client = APIClient.new(directory)
    access_token = Okta.Sync.get_access_token!(client, directory)
    synced_at = DateTime.utc_now()

    case APIClient.get_user(client, access_token, user_id) do
      {:ok, %Req.Response{status: 200, body: %{"id" => ^user_id} = user}} ->
        if Okta.Sync.syncable_user?(user) and assigned?(directory, client, access_token, user_id) do
          refresh_user(directory, client, access_token, synced_at, user)
        else
          remove_identity(directory, user_id)
        end

      {:ok, %Req.Response{status: 404}} ->
        remove_identity(directory, user_id)

      {:ok, response} ->
        raise Okta.SyncError, error: response, directory_id: directory.id, step: :get_user

      {:error, error} ->
        raise Okta.SyncError, error: error, directory_id: directory.id, step: :get_user
    end
  end

  defp apply_change(directory, "group", group_id) do
    Logger.info("Applying Okta group event", okta_directory_id: directory.id, group_id: group_id)
    client = APIClient.new(directory)
    access_token = Okta.Sync.get_access_token!(client, directory)
    synced_at = DateTime.utc_now()
    group = Database.get_group(directory.account_id, directory.id, group_id)

    case APIClient.get_group(client, access_token, group_id) do
      {:ok, %Req.Response{status: 200, body: %{"id" => ^group_id} = okta_group}} ->
        if assigned_group?(directory, client, access_token, group_id) do
          Okta.Sync.upsert_group(directory, synced_at, Okta.Sync.group_attrs(okta_group))
          Okta.Sync.sync_group_members(directory, client, access_token, synced_at, group_id)
        else
          remove_group(directory, group)
        end

      {:ok, %Req.Response{status: 404}} ->
        remove_group(directory, group)

      {:ok, response} ->
        raise Okta.SyncError, error: response, directory_id: directory.id, step: :get_group

      {:error, error} ->
        raise Okta.SyncError, error: error, directory_id: directory.id, step: :get_group
    end

    Portal.Policy.reconnect_orphaned_policies(directory.account_id)
    :ok
  end

  defp apply_change(directory, resource, _resource_id) do
    Logger.info("Ignoring Okta event for unsupported resource",
      okta_directory_id: directory.id,
      resource: resource
    )

    :ok
  end

  defp refresh_user(directory, client, access_token, synced_at, user) do
    case identity_attrs(directory, user) do
      {:ok, attrs} ->
        Okta.Sync.batch_upsert_identities(directory, synced_at, [attrs])
        Okta.Sync.sync_user_memberships(directory, client, access_token, synced_at, user["id"])

      {:error, error} ->
        Logger.warning(Exception.message(error), okta_directory_id: directory.id)
        :ok
    end
  end

  # A user without an email fails the full sync outright. One event is not
  # worth a retry storm, so the caller logs it and moves on.
  defp identity_attrs(directory, user) do
    {:ok, Okta.Sync.identity_attrs(user, directory.id)}
  rescue
    error in Okta.SyncError -> {:error, error}
  end

  defp assigned?(directory, client, access_token, user_id) do
    case APIClient.list_user_apps(client, access_token, user_id) do
      {:ok, %Req.Response{status: 200, body: apps}} when is_list(apps) ->
        apps != []

      {:ok, response} ->
        raise Okta.SyncError, error: response, directory_id: directory.id, step: :list_user_apps

      {:error, error} ->
        raise Okta.SyncError, error: error, directory_id: directory.id, step: :list_user_apps
    end
  end

  defp remove_identity(directory, user_id) do
    case Database.get_identity(directory.account_id, Okta.Sync.issuer(directory), user_id) do
      nil ->
        :ok

      identity ->
        {:ok, _} = DirectorySync.remove_identity(directory.id, identity)

        Logger.info("Removed identity from Okta event",
          okta_directory_id: directory.id,
          external_identity_id: identity.id
        )

        :ok
    end
  end

  defp assigned_group?(directory, client, access_token, group_id) do
    case APIClient.list_group_apps(client, access_token, group_id) do
      {:ok, %Req.Response{status: 200, body: apps}} when is_list(apps) ->
        apps != []

      {:ok, response} ->
        raise Okta.SyncError, error: response, directory_id: directory.id, step: :list_group_apps

      {:error, error} ->
        raise Okta.SyncError, error: error, directory_id: directory.id, step: :list_group_apps
    end
  end

  defp remove_group(_directory, nil), do: :ok

  defp remove_group(directory, group) do
    Database.delete_group(group)

    Logger.info("Removed group from Okta event",
      okta_directory_id: directory.id,
      group_id: group.id
    )

    :ok
  end

  defmodule Database do
    import Ecto.Query
    alias Portal.Safe

    def get_identity(account_id, issuer, idp_id) do
      from(i in Portal.ExternalIdentity,
        where: i.account_id == ^account_id,
        where: i.issuer == ^issuer,
        where: i.idp_id == ^idp_id
      )
      |> Safe.unscoped()
      |> Safe.one()
    end

    def get_group(account_id, directory_id, idp_id) do
      from(g in Portal.Group,
        where: g.account_id == ^account_id,
        where: g.directory_id == ^directory_id,
        where: g.idp_id == ^idp_id
      )
      |> Safe.unscoped()
      |> Safe.one()
    end

    def delete_group(group) do
      from(g in Portal.Group,
        where: g.account_id == ^group.account_id,
        where: g.id == ^group.id
      )
      |> Safe.unscoped()
      |> Safe.delete_all()
    end
  end
end
