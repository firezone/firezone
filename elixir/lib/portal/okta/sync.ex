defmodule Portal.Okta.Sync do
  @moduledoc """
  Worker to sync identities from Okta for a given directory.
  """
  use Oban.Worker,
    queue: :okta_sync,
    max_attempts: 1,
    unique: [
      period: :infinity,
      states: :incomplete,
      keys: [:directory_id]
    ]

  alias Portal.Okta
  alias __MODULE__.Database

  require Logger

  @syncable_okta_user_statuses ~w[
    ACTIVE
    STAGED
    PROVISIONED
    RECOVERY
    PASSWORD_EXPIRED
    LOCKED_OUT
  ]

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"account_id" => account_id, "directory_id" => directory_id}}) do
    Logger.info("Starting Okta directory sync",
      account_id: account_id,
      okta_directory_id: directory_id,
      timestamp: DateTime.utc_now()
    )

    case Database.get_directory(account_id, directory_id) do
      nil ->
        Logger.info("Okta directory not found, disabled, or account disabled, skipping",
          account_id: account_id,
          okta_directory_id: directory_id
        )

      directory ->
        sync(directory)
    end

    :ok
  end

  def perform(_), do: :ok

  defp update(directory, attrs) do
    changeset =
      Ecto.Changeset.cast(directory, attrs, [
        :synced_at,
        :error_email_count,
        :error_message,
        :errored_at,
        :is_disabled,
        :disabled_reason,
        :is_verified
      ])

    {:ok, _directory} = Database.update_directory(changeset)
  end

  defp sync(%Okta.Directory{} = directory) do
    client = Okta.APIClient.new(directory)
    access_token = get_access_token!(client, directory)
    verify_access_token!(client, access_token, directory)
    synced_at = DateTime.utc_now()

    apps = get_apps!(client, access_token, directory)
    sync_all_apps!(apps, client, access_token, directory, synced_at)
    sync_all_memberships!(client, access_token, directory, synced_at)
    check_deletion_threshold!(directory, synced_at)
    delete_unsynced(directory, synced_at)
    prune_tombstones(directory)

    # Reconnect orphaned policies after sync (groups may have been recreated)
    reconnected = Portal.Policy.reconnect_orphaned_policies(directory.account_id)

    if reconnected > 0 do
      Logger.info("Reconnected #{reconnected} orphaned policies after sync",
        account_id: directory.account_id,
        okta_directory_id: directory.id
      )
    end

    # Clear error state on successful sync completion
    update(directory, %{
      "synced_at" => synced_at,
      "error_email_count" => 0,
      "error_message" => nil,
      "errored_at" => nil,
      "is_disabled" => false,
      "disabled_reason" => nil
    })

    duration = DateTime.diff(DateTime.utc_now(), synced_at)

    Logger.info("Finished Okta directory sync in #{duration} seconds",
      okta_directory_id: directory.id
    )
  end

  defp get_access_token!(client, directory) do
    Logger.debug("Getting access token", okta_directory_id: directory.id)

    case Okta.APIClient.fetch_access_token(client) do
      {:ok, access_token} ->
        Logger.debug("Successfully obtained access token", okta_directory_id: directory.id)
        access_token

      {:error, error} ->
        Logger.debug("Failed to get access token",
          okta_directory_id: directory.id,
          error: inspect(error)
        )

        raise Okta.SyncError,
          error: error,
          directory_id: directory.id,
          step: :get_access_token
    end
  end

  @required_scopes ~w[okta.apps.read okta.users.read okta.groups.read]

  defp verify_access_token!(client, access_token, directory) do
    Logger.debug("Verifying access token scopes", okta_directory_id: directory.id)

    case Okta.APIClient.introspect_token(client, access_token) do
      {:ok, %{"scope" => raw_scopes}} ->
        scopes = String.split(raw_scopes, " ")
        missing_scopes = @required_scopes -- scopes

        if missing_scopes != [] do
          raise Okta.SyncError,
            error: {:scopes, "missing #{Enum.join(missing_scopes, ", ")}"},
            directory_id: directory.id,
            step: :verify_scopes
        end

      _ ->
        raise Okta.SyncError,
          error: {:scopes, "missing #{Enum.join(@required_scopes, ", ")}"},
          directory_id: directory.id,
          step: :verify_scopes
    end
  end

  defp get_apps!(client, token, directory) do
    Logger.debug("Fetching Okta apps", okta_directory_id: directory.id)

    case Okta.APIClient.list_apps(client, token) do
      {:ok, apps} ->
        Logger.debug("Successfully fetched Okta apps",
          okta_directory_id: directory.id,
          count: length(apps)
        )

        apps

      {:error, error} ->
        Logger.debug("Failed to fetch Okta apps",
          okta_directory_id: directory.id,
          error: inspect(error)
        )

        raise Okta.SyncError,
          error: error,
          directory_id: directory.id,
          step: :list_apps
    end
  end

  # Process all okta apps, syncing users and groups for each app
  defp sync_all_apps!(apps, client, token, directory, synced_at) do
    Enum.each(apps, fn app ->
      sync_single_app!(app, client, token, directory, synced_at)
    end)
  end

  # Sync a single okta app's users and groups in batches
  defp sync_single_app!(app, client, token, directory, synced_at) do
    app_id = app["id"]

    Logger.debug("Syncing app",
      okta_directory_id: directory.id,
      app_id: app_id
    )

    sync_app_identities_streaming!(app_id, client, token, directory, synced_at)
    sync_app_groups_streaming!(app_id, client, token, directory, synced_at)
  end

  # Stream and batch-insert identities for a specific app
  @batch_size 100
  defp sync_app_identities_streaming!(app_id, client, token, directory, synced_at) do
    Logger.debug("Streaming app users",
      okta_directory_id: directory.id,
      app_id: app_id
    )

    Okta.APIClient.stream_app_users(app_id, client, token)
    |> Stream.chunk_every(@batch_size)
    |> Stream.each(fn batch ->
      process_identity_batch!(batch, directory, synced_at)
    end)
    |> Stream.run()
  end

  defp process_identity_batch!(batch, directory, synced_at) do
    # Extract successful users and check for errors
    {users, errors} =
      Enum.reduce(batch, {[], []}, fn entry, acc ->
        reduce_identity_batch_entry(entry, acc, directory.id)
      end)

    # If there are any errors in the batch, raise the first one
    case errors do
      [error | _] ->
        raise Okta.SyncError,
          error: error,
          directory_id: directory.id,
          step: :stream_app_users

      [] ->
        account_id = directory.account_id
        issuer = issuer(directory)
        directory_id = directory.id
        parsed_users = Enum.map(users, &parse_okta_user(&1, directory_id))

        # Map users to identity attributes
        identity_attrs =
          Enum.map(parsed_users, fn user_data ->
            %{
              idp_id: user_data.okta_id,
              email: user_data.email,
              name: user_data.full_name,
              given_name: user_data.first_name,
              family_name: user_data.last_name,
              preferred_username: user_data.email
            }
          end)

        case Database.batch_upsert_identities(
               account_id,
               issuer,
               directory_id,
               synced_at,
               identity_attrs
             ) do
          {:ok, %{upserted_identities: count}} ->
            Logger.debug("Upserted #{count} identities", okta_directory_id: directory.id)
            :ok

          {:error, reason} ->
            Logger.error("Failed to upsert identities",
              reason: inspect(reason),
              count: length(identity_attrs),
              okta_directory_id: directory.id
            )

            raise Okta.SyncError,
              error: "Failed to upsert identities: #{inspect(reason)}",
              directory_id: directory.id,
              step: :batch_upsert_identities
        end
    end
  end

  defp reduce_identity_batch_entry({:ok, user_data}, {users, errors}, directory_id) do
    case fetch_embedded_map(user_data, ["_embedded", "user"], "user") do
      {:ok, user} ->
        if syncable_app_user?(user, directory_id) do
          {[user | users], errors}
        else
          {users, errors}
        end

      {:error, reason} ->
        {users, [reason | errors]}
    end
  end

  defp reduce_identity_batch_entry({:error, reason}, {users, errors}, _directory_id) do
    {users, [reason | errors]}
  end

  # Stream and batch-insert groups for a specific app
  defp sync_app_groups_streaming!(app_id, client, token, directory, synced_at) do
    Logger.debug("Streaming app groups",
      okta_directory_id: directory.id,
      app_id: app_id
    )

    Okta.APIClient.stream_app_groups(app_id, client, token)
    |> Stream.chunk_every(@batch_size)
    |> Stream.each(fn batch ->
      process_group_batch!(batch, directory, synced_at)
    end)
    |> Stream.run()
  end

  defp process_group_batch!(batch, directory, synced_at) do
    # Extract successful groups and check for errors
    {groups, errors} =
      Enum.reduce(batch, {[], []}, fn
        {:ok, group_data}, {groups, errors} ->
          case fetch_embedded_map(group_data, ["_embedded", "group"], "group") do
            {:ok, group} -> {[group | groups], errors}
            {:error, reason} -> {groups, [reason | errors]}
          end

        {:error, reason}, {groups, errors} ->
          {groups, [reason | errors]}
      end)

    # If there are any errors in the batch, raise the first one
    case errors do
      [error | _] ->
        raise Okta.SyncError,
          error: error,
          directory_id: directory.id,
          step: :stream_app_groups

      [] ->
        account_id = directory.account_id
        directory_id = directory.id

        group_attrs =
          Enum.map(groups, fn group ->
            parsed_group = parse_okta_group(group)

            %{
              idp_id: parsed_group.okta_id,
              name: parsed_group.name
            }
          end)

        unless Enum.empty?(group_attrs) do
          {:ok, %{upserted_groups: count}} =
            Database.batch_upsert_groups(account_id, directory_id, synced_at, group_attrs)

          Logger.debug("Upserted #{count} groups", okta_directory_id: directory.id)
        end

        :ok
    end
  end

  defp sync_all_memberships!(client, token, directory, synced_at) do
    account_id = directory.account_id
    issuer = issuer(directory)
    directory_id = directory.id

    Logger.debug("Syncing group memberships", okta_directory_id: directory.id)

    group_idp_ids = Database.get_synced_group_idp_ids(account_id, directory_id, synced_at)

    Logger.debug("Found synced groups",
      okta_directory_id: directory.id,
      count: length(group_idp_ids)
    )

    # Process groups in batches to avoid too many concurrent API calls
    group_idp_ids
    |> Enum.chunk_every(50)
    |> Enum.each(fn group_batch ->
      sync_membership_batch!(
        group_batch,
        client,
        token,
        account_id,
        issuer,
        directory_id,
        synced_at
      )
    end)
  end

  defp sync_membership_batch!(
         group_idp_ids,
         client,
         token,
         account_id,
         issuer,
         directory_id,
         synced_at
       ) do
    # Fetch memberships for all groups in this batch
    membership_tuples =
      Enum.flat_map(group_idp_ids, fn group_idp_id ->
        member_ids = fetch_group_members!(group_idp_id, client, token, directory_id)

        # Build tuples of (group_idp_id, user_idp_id) for each membership
        Enum.map(member_ids, fn member_id -> {group_idp_id, member_id} end)
      end)

    case Database.batch_upsert_memberships(
           account_id,
           issuer,
           directory_id,
           synced_at,
           membership_tuples
         ) do
      {:ok, %{upserted_memberships: count}} ->
        Logger.debug("Upserted #{count} memberships", okta_directory_id: directory_id)
        :ok

      {:error, reason} ->
        Logger.error("Failed to upsert memberships",
          reason: inspect(reason),
          count: length(membership_tuples),
          okta_directory_id: directory_id
        )

        raise Okta.SyncError,
          error: "Failed to upsert memberships: #{inspect(reason)}",
          directory_id: directory_id,
          step: :batch_upsert_memberships
    end
  end

  defp fetch_group_members!(group_idp_id, client, token, directory_id) do
    Okta.APIClient.stream_group_members(group_idp_id, client, token)
    |> Enum.reduce([], fn
      {:ok, member}, acc ->
        case syncable_group_member_id(member, group_idp_id, directory_id) do
          nil -> acc
          member_id -> [member_id | acc]
        end

      {:error, reason}, _acc ->
        raise Okta.SyncError,
          error: reason,
          directory_id: directory_id,
          step: :stream_group_members
    end)
    |> Enum.reverse()
  end

  defp syncable_group_member_id(member, group_idp_id, directory_id) do
    case Map.fetch(member, "status") do
      {:ok, status} ->
        if syncable_okta_user_status?(status), do: member["id"]

      :error ->
        Logger.error("Skipping Okta group member with missing status",
          okta_directory_id: directory_id,
          okta_group_idp_id: group_idp_id,
          okta_user_id: Map.get(member, "id", "unknown")
        )

        nil
    end
  end

  defp syncable_app_user?(user, directory_id) do
    case Map.fetch(user, "status") do
      {:ok, status} ->
        syncable_okta_user_status?(status)

      :error ->
        Logger.error("Skipping Okta app user with missing status",
          okta_directory_id: directory_id,
          okta_user_id: Map.get(user, "id", "unknown")
        )

        false
    end
  end

  defp syncable_okta_user_status?(status) do
    status in @syncable_okta_user_statuses
  end

  defp fetch_embedded_map(data, path, entity_name) do
    assignment_id = Map.get(data, "id", "unknown")

    case get_in(data, path) do
      value when is_map(value) ->
        {:ok, value}

      nil ->
        {:error,
         {:validation, "assignment '#{assignment_id}' missing '_embedded.#{entity_name}' payload"}}

      other ->
        {:error,
         {:validation,
          "assignment '#{assignment_id}' has invalid '_embedded.#{entity_name}' payload: #{inspect(other)}"}}
    end
  end

  # Helper to build issuer URL
  defp issuer(directory), do: "https://#{directory.okta_domain}"

  # Parses an Okta user API response into a structured map
  defp parse_okta_user(user, directory_id) do
    profile = user["profile"] || %{}

    email = profile["email"]

    unless email do
      raise Okta.SyncError,
        error: {:validation, "user '#{user["id"]}' missing 'email' field"},
        directory_id: directory_id,
        step: :process_user
    end

    first_name = (profile["firstName"] || "") |> String.trim()
    last_name = (profile["lastName"] || "") |> String.trim()
    email = email |> String.downcase() |> String.trim()

    %{
      okta_id: user["id"],
      email: email,
      first_name: first_name,
      last_name: last_name,
      full_name: "#{first_name} #{last_name}"
    }
  end

  # Parses an Okta group API response into a structured map
  defp parse_okta_group(group) do
    profile = group["profile"] || %{}

    %{
      okta_id: group["id"],
      name: profile["name"] || group["id"]
    }
  end

  # Delete records that weren't synced this time
  defp prune_tombstones(%{synced_at: nil}), do: :ok

  defp prune_tombstones(directory) do
    Database.prune_tombstones(directory.account_id, directory.id, directory.synced_at)
  end

  defp delete_unsynced(directory, synced_at) do
    account_id = directory.account_id
    directory_id = directory.id

    # Delete groups that weren't synced
    {deleted_groups_count, _} =
      Database.delete_unsynced_groups(account_id, directory_id, synced_at)

    Logger.debug("Deleted unsynced groups",
      okta_directory_id: directory.id,
      count: deleted_groups_count
    )

    # Delete identities that weren't synced
    {deleted_identities_count, _} =
      Database.delete_unsynced_identities(account_id, directory_id, synced_at)

    Logger.debug("Deleted unsynced identities",
      okta_directory_id: directory.id,
      count: deleted_identities_count
    )

    # Delete memberships that weren't synced
    {deleted_memberships_count, _} =
      Database.delete_unsynced_memberships(account_id, directory_id, synced_at)

    Logger.debug("Deleted unsynced group memberships",
      okta_directory_id: directory.id,
      count: deleted_memberships_count
    )

    # Delete actors that no longer have any identities and were created by this directory
    {deleted_actors_count, _} =
      Database.delete_actors_without_identities(account_id, directory_id)

    Logger.debug("Deleted actors without identities",
      okta_directory_id: directory.id,
      count: deleted_actors_count
    )
  end

  # Circuit breaker protection against accidental mass deletion
  # This can happen if someone misconfigures or removes the Okta app
  defp check_deletion_threshold!(directory, synced_at) do
    # Skip check on first sync - there's nothing to delete
    if is_nil(directory.synced_at) do
      Logger.debug("Skipping deletion threshold check - first sync",
        okta_directory_id: directory.id
      )
    else
      account_id = directory.account_id
      directory_id = directory.id

      # Get counts for identities
      identity_counts = Database.count_identities(account_id, directory_id, synced_at)

      # Get counts for groups
      group_counts = Database.count_groups(account_id, directory_id, synced_at)

      # Check identity deletion threshold
      check_resource_threshold!(
        identity_counts,
        "identities",
        directory
      )

      # Check group deletion threshold
      check_resource_threshold!(
        group_counts,
        "groups",
        directory
      )
    end
  end

  defp check_resource_threshold!(%{total: 0}, resource_name, directory) do
    Logger.debug(
      "Skipping deletion threshold check for #{resource_name} - no resources exist",
      okta_directory_id: directory.id
    )
  end

  defp check_resource_threshold!(counts, resource_name, directory) do
    %{total: total, to_delete: to_delete} = counts

    if to_delete == total do
      Logger.error(
        "Deletion threshold exceeded for #{resource_name}",
        okta_directory_id: directory.id
      )

      raise Okta.SyncError,
        error: {:circuit_breaker, "would delete all #{resource_name}"},
        directory_id: directory.id,
        step: :check_deletion_threshold
    end
  end

  defmodule Database do
    import Ecto.Query
    alias Portal.DirectorySync
    alias Portal.Safe

    def get_directory(account_id, id) do
      from(d in Okta.Directory,
        join: a in Portal.Account,
        on: a.id == d.account_id,
        where: d.account_id == ^account_id,
        where: d.id == ^id,
        where: d.is_disabled == false,
        where: a.is_disabled == false
      )
      |> Safe.unscoped()
      |> Safe.one()
    end

    def update_directory(changeset) do
      changeset |> Safe.unscoped() |> Safe.update()
    end

    # Count functions for circuit breaker threshold checks
    @spec count_identities(String.t(), String.t(), DateTime.t()) :: %{
            total: non_neg_integer(),
            to_delete: non_neg_integer()
          }
    def count_identities(account_id, directory_id, synced_at) do
      total =
        from(i in Portal.ExternalIdentity,
          where: i.account_id == ^account_id,
          where: i.directory_id == ^directory_id,
          select: count(i.id)
        )
        |> Safe.unscoped()
        |> Safe.one!()

      to_delete =
        from(i in Portal.ExternalIdentity,
          left_join: s in DirectorySync.IdentityState,
          on:
            s.account_id == i.account_id and s.directory_id == i.directory_id and
              s.idp_id == i.idp_id,
          where: i.account_id == ^account_id,
          where: i.directory_id == ^directory_id,
          where: is_nil(s.synced_at) or s.synced_at < ^synced_at,
          select: count(i.id)
        )
        |> Safe.unscoped()
        |> Safe.one!()

      %{total: total, to_delete: to_delete}
    end

    @spec count_groups(String.t(), String.t(), DateTime.t()) :: %{
            total: non_neg_integer(),
            to_delete: non_neg_integer()
          }
    def count_groups(account_id, directory_id, synced_at) do
      total =
        from(g in Portal.Group,
          where: g.account_id == ^account_id,
          where: g.directory_id == ^directory_id,
          select: count(g.id)
        )
        |> Safe.unscoped()
        |> Safe.one!()

      to_delete =
        from(g in Portal.Group,
          left_join: s in DirectorySync.GroupState,
          on:
            s.account_id == g.account_id and s.directory_id == g.directory_id and
              s.idp_id == g.idp_id,
          where: g.account_id == ^account_id,
          where: g.directory_id == ^directory_id,
          where: is_nil(s.synced_at) or s.synced_at < ^synced_at,
          select: count(g.id)
        )
        |> Safe.unscoped()
        |> Safe.one!()

      %{total: total, to_delete: to_delete}
    end

    def get_synced_group_idp_ids(account_id, directory_id, synced_at) do
      from(g in Portal.Group,
        join: s in DirectorySync.GroupState,
        on:
          s.account_id == g.account_id and s.directory_id == g.directory_id and
            s.idp_id == g.idp_id,
        where: g.account_id == ^account_id,
        where: g.directory_id == ^directory_id,
        where: s.synced_at == ^synced_at,
        where: not is_nil(g.idp_id),
        select: g.idp_id
      )
      |> Safe.unscoped()
      |> Safe.all()
    end

    def batch_upsert_identities(account_id, issuer, directory_id, synced_at, identities) do
      DirectorySync.batch_upsert_identities(
        account_id,
        issuer,
        directory_id,
        synced_at,
        identities,
        []
      )
    end

    def batch_upsert_groups(account_id, directory_id, synced_at, groups) do
      DirectorySync.batch_upsert_groups(account_id, directory_id, synced_at, groups, :group)
    end

    defdelegate batch_upsert_memberships(account_id, issuer, directory_id, synced_at, tuples),
      to: DirectorySync

    defdelegate delete_unsynced_groups(account_id, directory_id, synced_at),
      to: DirectorySync

    defdelegate delete_unsynced_identities(account_id, directory_id, synced_at),
      to: DirectorySync

    defdelegate delete_unsynced_memberships(account_id, directory_id, synced_at),
      to: DirectorySync

    defdelegate delete_actors_without_identities(account_id, directory_id),
      to: DirectorySync

    defdelegate prune_tombstones(account_id, directory_id, before), to: DirectorySync
  end
end
