defmodule Portal.Google.WebhookSync do
  @moduledoc """
  Oban worker that applies one Google Directory API user notification to the
  identities and org unit memberships of a Google directory.

  Notifications carry only the user id, so the worker re-reads the user and
  writes it with a fresh `synced_at`. The sync-state tables then make a slower
  full sync skip anything this worker wrote after that sync started, so the
  newer webhook read wins over the older full-sync read.

  A user is written when the directory already has an identity for them, or
  when org unit sync is on and the user sits in a tracked org unit. Group
  memberships come from group traversal and are left to the full sync.
  """

  use Oban.Worker, queue: :google_webhook, max_attempts: 3

  alias Portal.Google
  alias Portal.Google.APIClient
  alias Portal.DirectorySync.Lock
  alias __MODULE__.Database
  require Logger

  # Queued duplicates collapse into one job, but a notification that arrives
  # while a job is executing must still enqueue a fresh one, so :executing is
  # deliberately left out of the unique states.
  @unique [
    period: :infinity,
    states: [:available, :scheduled, :retryable],
    keys: [:directory_id, :user_id]
  ]

  # A full sync reads Google long before it writes, so a notification waits
  # for the directory lock instead of interleaving with one.
  @snooze_seconds 30

  @impl Oban.Worker
  def new(args, opts), do: super(args, Keyword.put_new(opts, :unique, @unique))

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{"account_id" => account_id, "directory_id" => directory_id, "user_id" => user_id}
      }) do
    case Google.Subscriptions.get_directory(account_id, directory_id) do
      nil ->
        Logger.info("Google directory not eligible for webhooks, skipping notification",
          google_directory_id: directory_id
        )

        :ok

      directory ->
        apply_with_lock(directory, user_id)
    end
  end

  def perform(_), do: :ok

  defp apply_with_lock(directory, user_id) do
    case Lock.try_run(:google, directory.id, fn -> apply_notification(directory, user_id) end) do
      {:ok, result} -> result
      :busy -> {:snooze, @snooze_seconds}
    end
  end

  defp apply_notification(directory, user_id) do
    Logger.info("Applying Google user notification",
      google_directory_id: directory.id,
      google_user_id: user_id
    )

    apply_change(directory, user_id)
  end

  defp apply_change(directory, user_id) do
    identity = Database.get_identity(directory, user_id)
    access_token = Google.Sync.get_access_token!(directory)
    synced_at = DateTime.utc_now()

    case APIClient.get_user(access_token, user_id) do
      {:ok, %Req.Response{status: 200, body: %{"id" => ^user_id} = user}} ->
        if Google.Sync.syncable_user?(user, directory.id) do
          refresh_user(directory, access_token, synced_at, identity, user)
        else
          remove_identity(directory, identity)
        end

      {:ok, %Req.Response{status: 404}} ->
        remove_identity(directory, identity)

      {:ok, response} ->
        raise Google.SyncError, error: response, directory_id: directory.id, step: :get_user

      {:error, error} ->
        raise Google.SyncError, error: error, directory_id: directory.id, step: :get_user
    end
  end

  defp refresh_user(directory, access_token, synced_at, identity, user) do
    org_unit_ids = tracked_org_unit_ids(directory, access_token, user["orgUnitPath"])

    if is_nil(identity) and org_unit_ids == [] do
      :ok
    else
      case upsert_identity(directory, synced_at, user) do
        :ok ->
          sync_org_unit_memberships(directory, synced_at, user["id"], org_unit_ids)
          remove_identity_without_memberships(directory, user["id"])

        :skipped ->
          :ok
      end
    end
  end

  # Identities only exist through a synced group or org unit, so a user who
  # left their last one is gone as far as this directory is concerned.
  defp remove_identity_without_memberships(directory, user_id) do
    case Database.get_identity(directory, user_id) do
      nil ->
        :ok

      identity ->
        if Database.directory_membership_exists?(directory, identity.actor_id) do
          :ok
        else
          remove_identity(directory, identity)
        end
    end
  end

  defp upsert_identity(directory, synced_at, user) do
    case identity_attrs(directory, user) do
      {:ok, attrs} ->
        Google.Sync.batch_upsert_identities(directory, synced_at, [attrs])

      {:error, error} ->
        Logger.warning(Exception.message(error), google_directory_id: directory.id)
        :skipped
    end
  end

  # A user without a primary email fails the full sync outright. One
  # notification is not worth a retry storm, so the caller logs it and moves on.
  defp identity_attrs(directory, user) do
    {:ok, Google.Sync.map_user_to_identity(user, directory.id)}
  rescue
    error in Google.SyncError -> {:error, error}
  end

  # A user belongs to their org unit and every org unit above it, which is what
  # the full sync's `orgUnitPath=` query returns.
  defp tracked_org_unit_ids(%{orgunit_sync_enabled: false}, _access_token, _path), do: []

  defp tracked_org_unit_ids(directory, access_token, user_path) when is_binary(user_path) do
    APIClient.stream_organization_units(access_token)
    |> Enum.flat_map(fn
      {:error, error} ->
        raise Google.SyncError,
          error: error,
          directory_id: directory.id,
          step: :stream_org_units

      org_units when is_list(org_units) ->
        for %{"orgUnitId" => id, "orgUnitPath" => path} <- org_units,
            is_binary(id) and is_binary(path),
            contains_path?(path, user_path),
            do: id
    end)
  end

  defp tracked_org_unit_ids(_directory, _access_token, _path), do: []

  defp contains_path?("/", _user_path), do: true

  defp contains_path?(org_unit_path, user_path) do
    org_unit_path == user_path or String.starts_with?(user_path, org_unit_path <> "/")
  end

  defp sync_org_unit_memberships(%{orgunit_sync_enabled: false}, _synced_at, _user_id, _ids),
    do: :ok

  defp sync_org_unit_memberships(directory, synced_at, user_id, org_unit_ids) do
    memberships = Enum.map(org_unit_ids, &{&1, user_id})

    if memberships != [] do
      Google.Sync.batch_upsert_memberships(directory, synced_at, memberships)
    end

    case Database.get_identity(directory, user_id) do
      nil ->
        :ok

      identity ->
        {deleted, _} = Database.delete_unsynced_org_unit_memberships(directory, identity, synced_at)

        Logger.debug("Resynced org unit memberships from Google user notification",
          google_directory_id: directory.id,
          google_user_id: user_id,
          deleted_memberships: deleted
        )

        :ok
    end
  end

  defp remove_identity(_directory, nil), do: :ok

  defp remove_identity(directory, identity) do
    Database.delete_identity(identity)
    Database.delete_actor_directory_memberships(directory, identity.actor_id)
    Google.Sync.delete_actors_without_identities(directory)

    Logger.info("Removed identity from Google user notification",
      google_directory_id: directory.id,
      external_identity_id: identity.id
    )

    :ok
  end

  defmodule Database do
    import Ecto.Query
    alias Portal.Safe

    def get_identity(directory, idp_id) do
      issuer = Portal.Google.Sync.issuer()

      from(i in Portal.ExternalIdentity,
        where: i.account_id == ^directory.account_id,
        where: i.directory_id == ^directory.id,
        where: i.issuer == ^issuer,
        where: i.idp_id == ^idp_id
      )
      |> Safe.unscoped()
      |> Safe.one()
    end

    def directory_membership_exists?(directory, actor_id) do
      from(m in Portal.Membership,
        join: g in Portal.Group,
        on: m.group_id == g.id and m.account_id == g.account_id,
        where: m.account_id == ^directory.account_id,
        where: m.actor_id == ^actor_id,
        where: g.directory_id == ^directory.id
      )
      |> Safe.unscoped()
      |> Safe.exists?()
    end

    def delete_identity(identity) do
      from(i in Portal.ExternalIdentity,
        where: i.account_id == ^identity.account_id,
        where: i.id == ^identity.id
      )
      |> Safe.unscoped()
      |> Safe.delete_all()
    end

    def delete_actor_directory_memberships(directory, actor_id) do
      from(m in Portal.Membership,
        join: g in Portal.Group,
        on: m.group_id == g.id and m.account_id == g.account_id,
        where: m.account_id == ^directory.account_id,
        where: m.actor_id == ^actor_id,
        where: g.directory_id == ^directory.id
      )
      |> Safe.unscoped()
      |> Safe.delete_all()
    end

    def delete_unsynced_org_unit_memberships(directory, identity, synced_at) do
      from(m in Portal.Membership,
        join: g in Portal.Group,
        on: m.group_id == g.id and m.account_id == g.account_id,
        where: m.account_id == ^directory.account_id,
        where: m.actor_id == ^identity.actor_id,
        where: g.directory_id == ^directory.id,
        where: g.entity_type == :org_unit,
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
