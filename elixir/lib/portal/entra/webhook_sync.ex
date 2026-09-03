defmodule Portal.Entra.WebhookSync do
  @moduledoc """
  Oban worker that applies one Microsoft Graph change notification to the
  identities, groups, and memberships of an Entra directory.

  Notifications carry no resource data, so the worker re-reads the object from
  Graph and writes it with a fresh `synced_at`. The sync-state tables then make
  a slower full sync skip anything this worker wrote after that sync started,
  so the newer webhook read wins over the older full-sync read.

  Users are only updated when this directory already has an identity for them,
  and groups only when the directory already tracks them (or syncs all
  groups). Everything else is left to the full sync, which is the only place
  that knows about app role assignments.
  """

  use Oban.Worker, queue: :entra_webhook, max_attempts: 3

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

  # A full sync reads Graph long before it writes. If a webhook deleted a row
  # in between, the sync would insert the stale copy back without a sync-state
  # guard to stop it. Waiting for the sync to finish avoids that.
  @snooze_seconds 30

  @impl Oban.Worker
  def new(args, opts), do: super(args, Keyword.put_new(opts, :unique, @unique))

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{
          "account_id" => account_id,
          "directory_id" => directory_id,
          "resource" => resource,
          "resource_id" => resource_id,
          "change_type" => change_type
        }
      }) do
    directory = Entra.Subscriptions.get_directory(account_id, directory_id)

    cond do
      is_nil(directory) ->
        Logger.info("Entra directory not eligible for webhooks, skipping notification",
          entra_directory_id: directory_id
        )

        :ok

      Database.full_sync_running?(directory_id) ->
        {:snooze, @snooze_seconds}

      true ->
        Logger.info("Applying Entra change notification",
          entra_directory_id: directory.id,
          resource: resource,
          resource_id: resource_id,
          change_type: change_type
        )

        apply_change(directory, resource, resource_id, change_type)
    end
  end

  def perform(_), do: :ok

  defp apply_change(directory, "user", user_id, change_type) do
    case Database.get_identity(directory.account_id, Entra.Sync.issuer(directory), user_id) do
      nil -> :ok
      identity when change_type == "deleted" -> remove_identity(directory, identity)
      identity -> refresh_identity(directory, identity, user_id)
    end
  end

  defp apply_change(directory, "group", group_id, change_type) do
    group = Database.get_group(directory.account_id, directory.id, group_id)

    cond do
      change_type == "deleted" ->
        remove_group(directory, group)

      is_nil(group) and not directory.sync_all_groups ->
        :ok

      true ->
        access_token = Entra.Sync.get_access_token!(directory)
        synced_at = DateTime.utc_now()

        case APIClient.get_group(access_token, group_id) do
          {:ok, %Req.Response{status: 200, body: %{"id" => id, "displayName" => name}}}
          when is_binary(id) and is_binary(name) ->
            resync_group(directory, access_token, synced_at, id, name)
            resync_parent_groups(directory, access_token, synced_at, id)
            Portal.Policy.reconnect_orphaned_policies(directory.account_id)
            :ok

          {:ok, %Req.Response{status: 404}} ->
            remove_group(directory, group)

          {:ok, response} ->
            raise Entra.SyncError, error: response, directory_id: directory.id, step: :get_group

          {:error, error} ->
            raise Entra.SyncError, error: error, directory_id: directory.id, step: :get_group
        end
    end
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
    Database.delete_identity(identity)
    Database.delete_actor_directory_memberships(directory.account_id, directory.id, identity.actor_id)
    Entra.Sync.delete_actors_without_identities(directory)

    Logger.info("Removed identity from Entra change notification",
      entra_directory_id: directory.id,
      external_identity_id: identity.id
    )

    :ok
  end

  defp resync_group(directory, access_token, synced_at, group_id, group_name) do
    Entra.Sync.batch_upsert_groups(directory, synced_at, [%{idp_id: group_id, name: group_name}])

    Entra.Sync.sync_group_members(directory, access_token, synced_at, group_id, group_name)

    case Database.get_group(directory.account_id, directory.id, group_id) do
      nil ->
        :ok

      group ->
        {deleted, _} = Database.delete_unsynced_group_memberships(group, synced_at)

        Logger.debug("Resynced group from Entra change notification",
          entra_directory_id: directory.id,
          group_id: group_id,
          deleted_memberships: deleted
        )

        :ok
    end
  end

  # A member change on a nested group changes the transitive members of every
  # group above it, but Graph only notifies about the group that changed.
  defp resync_parent_groups(directory, access_token, synced_at, group_id) do
    APIClient.stream_group_transitive_member_of_groups(access_token, group_id)
    |> Stream.each(fn
      {:error, error} ->
        raise Entra.SyncError,
          error: error,
          directory_id: directory.id,
          step: :stream_group_transitive_member_of_groups

      parents when is_list(parents) ->
        Enum.each(parents, &resync_parent_group(directory, access_token, synced_at, &1))
    end)
    |> Stream.run()
  end

  defp resync_parent_group(directory, access_token, synced_at, parent) do
    with id when is_binary(id) <- parent["id"],
         name when is_binary(name) <- parent["displayName"],
         true <- tracked_group?(directory, id) do
      resync_group(directory, access_token, synced_at, id, name)
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

    def full_sync_running?(directory_id) do
      [worker: Portal.Entra.Sync, state: :executing]
      |> Oban.Job.query()
      |> where([j], fragment("?->>'directory_id'", j.args) == ^directory_id)
      |> Safe.unscoped()
      |> Safe.exists?()
    end

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

    def delete_identity(identity) do
      from(i in Portal.ExternalIdentity,
        where: i.account_id == ^identity.account_id,
        where: i.id == ^identity.id
      )
      |> Safe.unscoped()
      |> Safe.delete_all()
    end

    def delete_actor_directory_memberships(account_id, directory_id, actor_id) do
      from(m in Portal.Membership,
        join: g in Portal.Group,
        on: m.group_id == g.id and m.account_id == g.account_id,
        where: m.account_id == ^account_id,
        where: m.actor_id == ^actor_id,
        where: g.directory_id == ^directory_id
      )
      |> Safe.unscoped()
      |> Safe.delete_all()
    end

    def delete_unsynced_group_memberships(group, synced_at) do
      from(m in Portal.Membership,
        where: m.account_id == ^group.account_id,
        where: m.group_id == ^group.id,
        where:
          fragment(
            "NOT EXISTS (SELECT 1 FROM membership_sync_states mss WHERE mss.membership_id = ? AND mss.account_id = ? AND mss.synced_at >= ?)",
            m.id,
            m.account_id,
            ^synced_at
          )
      )
      |> Safe.unscoped()
      |> Safe.delete_all()
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
