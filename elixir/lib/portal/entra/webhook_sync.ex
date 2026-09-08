defmodule Portal.Entra.WebhookSync do
  @moduledoc """
  Oban worker that applies one Microsoft Graph change notification to the
  identities, groups, and memberships of an Entra directory.

  Notifications carry no resource data, so the worker re-reads the object from
  Graph and writes it with a fresh `synced_at`. Jobs for one directory run one
  at a time (see `Portal.DirectorySync`), so a notification that arrives during
  a full sync is applied by a fresh read after that sync finished.

  Users are only updated when this directory already has an identity for them,
  and groups only when the directory already tracks them (or syncs all
  groups). Everything else is left to the full sync, which is the only place
  that knows about app role assignments.
  """

  use Oban.Worker, queue: :entra_webhook, max_attempts: 3

  alias Portal.DirectorySync
  alias Portal.Entra
  alias Portal.Microsoft.Graph.APIClient
  alias __MODULE__.Database
  require Logger

  # Queued duplicates collapse into one job, but a notification that arrives
  # while a job is executing must still enqueue a fresh one, so :executing is
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
            "resource_id" => resource_id,
            "change_type" => change_type
          }
        } = job
      ) do
    case Entra.Subscriptions.get_directory(account_id, directory_id) do
      nil ->
        Logger.info("Entra directory not eligible for webhooks, skipping notification",
          entra_directory_id: directory_id
        )

        :ok

      directory ->
        DirectorySync.run_alone(:entra, directory.id, job, fn ->
          apply_notification(directory, resource, resource_id, change_type)
        end)
    end
  end

  def perform(_), do: :ok

  defp apply_notification(directory, resource, resource_id, change_type) do
    Logger.info("Applying Entra change notification",
      entra_directory_id: directory.id,
      resource: resource,
      resource_id: resource_id,
      change_type: change_type
    )

    apply_change(directory, resource, resource_id, change_type)
  end

  # A notification is only a ping: the object is always re-read, so a queued
  # deletion that Graph has since undone refreshes the object instead.
  defp apply_change(directory, "user", user_id, _change_type) do
    case Database.get_identity(directory.account_id, Entra.Sync.issuer(directory), user_id) do
      nil -> :ok
      identity -> refresh_identity(directory, identity, user_id)
    end
  end

  defp apply_change(directory, "group", group_id, _change_type) do
    access_token = Entra.Sync.get_access_token!(directory)
    synced_at = DateTime.utc_now()

    case fetch_group(directory, access_token, group_id) do
      {:ok, id, name} ->
        fetched =
          if tracked_group?(directory, id) do
            resync_group(directory, access_token, synced_at, id, name, %{})
          else
            %{}
          end

        # An untracked child still changes the transitive members of every
        # tracked group above it.
        resync_stored_parents(directory, access_token, synced_at, id, fetched)

      # Graph cannot name the former parents of a deleted group, so they come
      # from the nesting each tracked group recorded while its members were
      # fresh.
      :not_found ->
        remove_group(directory, Database.get_group(directory.account_id, directory.id, group_id))
        resync_stored_parents(directory, access_token, synced_at, group_id, %{})
    end

    Portal.Policy.reconnect_orphaned_policies(directory.account_id)
    :ok
  end

  defp apply_change(directory, resource, _resource_id, _change_type) do
    Logger.info("Ignoring Entra notification for unsupported resource",
      entra_directory_id: directory.id,
      resource: resource
    )

    :ok
  end

  defp refresh_identity(directory, identity, user_id) do
    access_token = Entra.Sync.get_access_token!(directory)
    synced_at = DateTime.utc_now()

    case APIClient.get_user(access_token, user_id) do
      {:ok, %Req.Response{status: 200, body: %{} = user}} ->
        if Entra.Sync.syncable_user?(user, directory.id) do
          upsert_identity(directory, synced_at, user)
        else
          remove_identity(directory, identity)
        end

      {:ok, %Req.Response{status: 404}} ->
        remove_identity(directory, identity)

      {:ok, response} ->
        raise Entra.SyncError, error: response, directory_id: directory.id, step: :get_user

      {:error, error} ->
        raise Entra.SyncError, error: error, directory_id: directory.id, step: :get_user
    end
  end

  defp upsert_identity(directory, synced_at, user) do
    case identity_attrs(directory, user) do
      {:ok, attrs} ->
        Entra.Sync.batch_upsert_identities(directory, synced_at, [attrs])

      {:error, error} ->
        Logger.warning(Exception.message(error), entra_directory_id: directory.id)
        :ok
    end
  end

  # A user without a valid email fails the full sync outright. One notification
  # is not worth a retry storm, so the caller logs it and moves on.
  defp identity_attrs(directory, user) do
    {:ok, Entra.Sync.map_user_to_identity(user, directory.id, directory.email_field)}
  rescue
    error in Entra.SyncError -> {:error, error}
  end

  defp remove_identity(directory, identity) do
    {:ok, _} = DirectorySync.remove_identity(directory.id, identity)

    Logger.info("Removed identity from Entra change notification",
      entra_directory_id: directory.id,
      external_identity_id: identity.id
    )

    :ok
  end

  defp resync_group(directory, access_token, synced_at, group_id, group_name, fetched) do
    Entra.Sync.batch_upsert_groups(directory, synced_at, [%{idp_id: group_id, name: group_name}])
    Entra.Sync.sync_group_members(directory, access_token, synced_at, group_id, group_name, fetched)
  end

  # Parents come from the nesting recorded at sync time, not from Graph. One
  # cache serves the whole job, so a group under several parents is read once.
  defp resync_stored_parents(directory, access_token, synced_at, group_id, fetched) do
    directory
    |> Entra.Sync.parents_of(group_id)
    |> Enum.reduce(fetched, &resync_stored_parent(directory, access_token, synced_at, &1, &2))
  end

  defp resync_stored_parent(directory, access_token, synced_at, parent, fetched) do
    case fetch_group(directory, access_token, parent.idp_id) do
      {:ok, id, name} ->
        resync_group(directory, access_token, synced_at, id, name, fetched)

      :not_found ->
        remove_group(directory, parent)
        fetched
    end
  end

  defp fetch_group(directory, access_token, group_id) do
    case APIClient.get_group(access_token, group_id) do
      {:ok, %Req.Response{status: 200, body: %{"id" => id, "displayName" => name}}}
      when is_binary(id) and is_binary(name) ->
        {:ok, id, name}

      {:ok, %Req.Response{status: 404}} ->
        :not_found

      {:ok, response} ->
        raise Entra.SyncError, error: response, directory_id: directory.id, step: :get_group

      {:error, error} ->
        raise Entra.SyncError, error: error, directory_id: directory.id, step: :get_group
    end
  end

  defp tracked_group?(%{sync_all_groups: true}, _group_id), do: true

  defp tracked_group?(directory, group_id) do
    not is_nil(Database.get_group(directory.account_id, directory.id, group_id))
  end

  defp remove_group(_directory, nil), do: :ok

  defp remove_group(directory, group) do
    Database.delete_group(group)

    Logger.info("Removed group from Entra change notification",
      entra_directory_id: directory.id,
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
