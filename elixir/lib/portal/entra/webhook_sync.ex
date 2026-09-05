defmodule Portal.Entra.WebhookSync do
  @moduledoc """
  Oban worker that applies one Microsoft Graph change notification to the
  identities, groups, and memberships of an Entra directory.

  Notifications carry no resource data, so the worker re-reads the object from
  Graph and writes it with a fresh `synced_at`. The sync-state tables then make
  a slower full sync skip anything this worker wrote after that sync started,
  so the newer webhook read wins over the older full-sync read. An object that
  is gone, or a group that is no longer assigned to a Firezone app, leaves a
  tombstone behind even when this directory never inserted it, so a full sync
  page fetched before the change cannot insert it later.

  Users are only inserted by the full sync, which is the only place that knows
  about app role assignments; a webhook refreshes or removes the identities it
  already has. Groups are synced when the directory syncs all groups, or when
  the group is assigned to one of the directory's Firezone apps.
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

  # Tombstones older than the grace period are pruned, so a job must not
  # outlive it with an older timestamp.
  @impl Oban.Worker
  def timeout(_job), do: :timer.seconds(div(DirectorySync.tombstone_grace_seconds(), 2))

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
    case Entra.Subscriptions.get_directory(account_id, directory_id) do
      nil ->
        Logger.info("Entra directory not eligible for webhooks, skipping notification",
          entra_directory_id: directory_id
        )

        :ok

      directory ->
        apply_notification(directory, resource, resource_id, change_type)
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

  defp apply_change(directory, "user", user_id, "deleted") do
    remove_identity(directory, user_id, DateTime.utc_now())
  end

  defp apply_change(directory, "user", user_id, _change_type) do
    synced_at = DateTime.utc_now()
    known? = Database.identity_exists?(directory.account_id, Entra.Sync.issuer(directory), user_id)
    access_token = Entra.Sync.get_access_token!(directory)

    case APIClient.get_user(access_token, user_id) do
      {:ok, %Req.Response{status: 200, body: %{} = user}} ->
        cond do
          not Entra.Sync.syncable_user?(user, directory.id) ->
            remove_identity(directory, user_id, synced_at)

          known? ->
            upsert_identity(directory, synced_at, user)

          true ->
            :ok
        end

      {:ok, %Req.Response{status: 404}} ->
        remove_identity(directory, user_id, synced_at)

      {:ok, response} ->
        raise Entra.SyncError, error: response, directory_id: directory.id, step: :get_user

      {:error, error} ->
        raise Entra.SyncError, error: error, directory_id: directory.id, step: :get_user
    end
  end

  defp apply_change(directory, "group", group_id, "deleted") do
    remove_group(directory, group_id, DateTime.utc_now())
  end

  defp apply_change(directory, "group", group_id, _change_type) do
    synced_at = DateTime.utc_now()
    access_token = Entra.Sync.get_access_token!(directory)
    assignment_check = assignment_check(directory, access_token)

    if eligible_group?(directory, access_token, assignment_check, group_id) do
      case APIClient.get_group(access_token, group_id) do
        {:ok, %Req.Response{status: 200, body: %{"id" => id, "displayName" => name}}}
        when is_binary(id) and is_binary(name) ->
          resync_group(directory, access_token, synced_at, id, name)
          resync_parent_groups(directory, access_token, synced_at, assignment_check, id)
          Portal.Policy.reconnect_orphaned_policies(directory.account_id)
          :ok

        {:ok, %Req.Response{status: 404}} ->
          remove_group(directory, group_id, synced_at)

        {:ok, response} ->
          raise Entra.SyncError, error: response, directory_id: directory.id, step: :get_group

        {:error, error} ->
          raise Entra.SyncError, error: error, directory_id: directory.id, step: :get_group
      end
    else
      remove_group(directory, group_id, synced_at)
    end
  end

  defp apply_change(directory, resource, _resource_id, _change_type) do
    Logger.info("Ignoring Entra notification for unsupported resource",
      entra_directory_id: directory.id,
      resource: resource
    )

    :ok
  end

  defp upsert_identity(directory, synced_at, user) do
    case identity_attrs(directory, user) do
      {:ok, attrs} ->
        Entra.Sync.batch_upsert_identities(directory, synced_at, [attrs], eligible: false)

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

  defp remove_identity(directory, user_id, synced_at) do
    {removed, _} =
      DirectorySync.remove_identity(
        directory.account_id,
        directory.id,
        Entra.Sync.issuer(directory),
        user_id,
        synced_at
      )

    Entra.Sync.delete_actors_without_identities(directory)

    Logger.info("Removed identity from Entra change notification",
      entra_directory_id: directory.id,
      user_id: user_id,
      removed: removed
    )

    :ok
  end

  # A directory that syncs assigned groups only must check the assignment
  # itself: a refresh of a tracked group would otherwise keep a group the full
  # sync found unassigned alive through the cleanup.
  defp assignment_check(%{sync_all_groups: true}, _access_token), do: :all_groups

  defp assignment_check(directory, access_token) do
    {:assigned_to, Entra.Sync.service_principal_ids(directory, access_token)}
  end

  defp eligible_group?(_directory, _access_token, :all_groups, _group_id), do: true

  defp eligible_group?(directory, access_token, {:assigned_to, service_principal_ids}, group_id) do
    case APIClient.list_group_app_role_assignments(access_token, group_id) do
      {:ok, %Req.Response{status: 200, body: %{"value" => assignments}}}
      when is_list(assignments) ->
        Enum.any?(assignments, &(&1["resourceId"] in service_principal_ids))

      {:ok, %Req.Response{status: 404}} ->
        false

      {:ok, response} ->
        raise Entra.SyncError,
          error: response,
          directory_id: directory.id,
          step: :list_group_app_role_assignments

      {:error, error} ->
        raise Entra.SyncError,
          error: error,
          directory_id: directory.id,
          step: :list_group_app_role_assignments
    end
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
  defp resync_parent_groups(directory, access_token, synced_at, assignment_check, group_id) do
    APIClient.stream_group_transitive_member_of_groups(access_token, group_id)
    |> Stream.each(fn
      {:error, error} ->
        raise Entra.SyncError,
          error: error,
          directory_id: directory.id,
          step: :stream_group_transitive_member_of_groups

      parents when is_list(parents) ->
        Enum.each(
          parents,
          &resync_parent_group(directory, access_token, synced_at, assignment_check, &1)
        )
    end)
    |> Stream.run()
  end

  defp resync_parent_group(directory, access_token, synced_at, assignment_check, parent) do
    with id when is_binary(id) <- parent["id"],
         name when is_binary(name) <- parent["displayName"] do
      if eligible_group?(directory, access_token, assignment_check, id) do
        resync_group(directory, access_token, synced_at, id, name)
      else
        remove_group(directory, id, synced_at)
      end
    end
  end

  defp remove_group(directory, group_id, synced_at) do
    {removed, _} =
      DirectorySync.remove_group(directory.account_id, directory.id, group_id, synced_at)

    Logger.info("Removed group from Entra change notification",
      entra_directory_id: directory.id,
      group_id: group_id,
      removed: removed
    )

    :ok
  end

  defmodule Database do
    import Ecto.Query
    alias Portal.Safe

    def identity_exists?(account_id, issuer, idp_id) do
      from(i in Portal.ExternalIdentity,
        where: i.account_id == ^account_id,
        where: i.issuer == ^issuer,
        where: i.idp_id == ^idp_id
      )
      |> Safe.unscoped()
      |> Safe.exists?()
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
  end
end
