defmodule Portal.Entra.Sync do
  @moduledoc """
  Oban worker for syncing users, groups, and memberships from Entra ID.
  """
  use Oban.Worker,
    queue: :entra_sync,
    max_attempts: 1,
    unique: [
      period: :infinity,
      states: :incomplete,
      keys: [:directory_id]
    ]

  alias Portal.Entra
  alias Portal.Microsoft.Graph.APIClient
  alias __MODULE__.Database
  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"account_id" => account_id, "directory_id" => directory_id}}) do
    run_sync(account_id, directory_id)
    :ok
  end

  def perform(_), do: :ok

  defp run_sync(account_id, directory_id) do
    Logger.info("Starting Entra directory sync",
      account_id: account_id,
      entra_directory_id: directory_id,
      timestamp: DateTime.utc_now()
    )

    case Database.get_directory(account_id, directory_id) do
      nil ->
        Logger.info("Entra directory not found, disabled, or account disabled, skipping",
          account_id: account_id,
          entra_directory_id: directory_id
        )

      directory ->
        sync(directory)
    end
  end

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

  defp sync(%Entra.Directory{} = directory) do
    access_token = get_access_token!(directory)
    synced_at = DateTime.utc_now()

    fetch_and_sync_all(directory, access_token, synced_at)
    delete_unsynced(directory, synced_at)
    prune_tombstones(directory)

    # Reconnect orphaned policies after sync (groups may have been recreated)
    reconnected = Portal.Policy.reconnect_orphaned_policies(directory.account_id)

    if reconnected > 0 do
      Logger.info("Reconnected #{reconnected} orphaned policies after sync",
        account_id: directory.account_id,
        entra_directory_id: directory.id
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

    Logger.info("Finished Entra directory sync in #{duration} seconds",
      entra_directory_id: directory.id
    )

    {:ok, _job} =
      %{account_id: directory.account_id, directory_id: directory.id, action: "ensure"}
      |> Entra.Subscriptions.new()
      |> Oban.insert()
  end

  @doc """
  Streams the transitive members of one group and upserts their identities and
  memberships. Shared by the full sync and the webhook worker.
  """
  def sync_group_members(directory, access_token, synced_at, group_id, group_name) do
    Logger.debug("Streaming transitive members for group",
      entra_directory_id: directory.id,
      group_id: group_id,
      group_name: group_name
    )

    APIClient.stream_group_transitive_members(access_token, group_id)
    |> Stream.each(fn
      {:error, error} ->
        raise Entra.SyncError,
          error: error,
          directory_id: directory.id,
          step: :stream_group_transitive_members

      members when is_list(members) ->
        process_group_members_page(directory, synced_at, group_id, group_name, members)
    end)
    |> Stream.run()
  end

  def issuer(directory), do: "https://login.microsoftonline.com/#{directory.tenant_id}/v2.0"

  def get_directory(account_id, directory_id), do: Database.get_directory(account_id, directory_id)

  def delete_actors_without_identities(directory) do
    Database.delete_actors_without_identities(directory.account_id, directory.id)
  end

  def get_access_token!(directory) do
    Logger.debug("Getting access token", entra_directory_id: directory.id)

    case APIClient.get_access_token(:entra, directory.tenant_id) do
      {:ok, %{body: %{"access_token" => access_token}}} ->
        Logger.debug("Successfully obtained access token", entra_directory_id: directory.id)

        access_token

      {:ok, response} ->
        Logger.debug("Invalid access token response",
          entra_directory_id: directory.id,
          status: response.status,
          body: inspect(response.body)
        )

        raise Entra.SyncError,
          error: response,
          directory_id: directory.id,
          step: :get_access_token

      {:error, error} ->
        Logger.debug("Failed to get access token",
          entra_directory_id: directory.id,
          error: inspect(error)
        )

        raise Entra.SyncError,
          error: error,
          directory_id: directory.id,
          step: :get_access_token
    end
  end

  defp fetch_and_sync_all(directory, access_token, synced_at) do
    if directory.sync_all_groups do
      # Sync all groups from the directory
      sync_all_groups(directory, access_token, synced_at)
    else
      # Sync only assigned groups (via app role assignments)
      sync_assigned_groups(directory, access_token, synced_at)
    end
  end

  defp sync_assigned_groups(directory, access_token, synced_at) do
    # Directory Sync app is REQUIRED - fail if not found (consent may have been revoked)
    directory_sync_sp_id = fetch_directory_sync_service_principal!(directory, access_token)

    # Auth Provider app is optional (deprecated) - returns nil if not found
    auth_provider_sp_id = fetch_auth_provider_service_principal(directory, access_token)

    sync_assignments(directory, access_token, synced_at, directory_sync_sp_id)

    # DEPRECATED: Also sync assignments from the Authentication app for backwards compatibility.
    # This supports existing Entra directory sync setups that have users assigned to the
    # Authentication app rather than the Directory Sync app.
    # TODO: Remove this once all customers have migrated to assigning users to the
    # Directory Sync app.
    if auth_provider_sp_id do
      sync_assignments(directory, access_token, synced_at, auth_provider_sp_id)
    end

    :ok
  end

  defp fetch_directory_sync_service_principal!(directory, access_token) do
    case fetch_service_principal_id(directory, access_token, :directory_sync) do
      {:ok, id} ->
        id

      {:error, {:not_found, _response}} ->
        raise Entra.SyncError,
          error:
            {:consent_revoked,
             "Directory Sync app service principal not found. Please re-grant admin consent."},
          directory_id: directory.id,
          step: :fetch_directory_sync_service_principal

      {:error, {:request_failed, error}} ->
        raise Entra.SyncError,
          error: error,
          directory_id: directory.id,
          step: :fetch_directory_sync_service_principal
    end
  end

  defp fetch_auth_provider_service_principal(directory, access_token) do
    case fetch_service_principal_id(directory, access_token, :auth_provider) do
      {:ok, id} ->
        id

      {:error, {:not_found, _response}} ->
        Logger.debug("Auth Provider app service principal not found, skipping (deprecated app)",
          entra_directory_id: directory.id
        )

        nil

      {:error, {:request_failed, error}} ->
        Logger.info("Failed to fetch Auth Provider service principal, skipping",
          entra_directory_id: directory.id,
          error: inspect(error)
        )

        nil
    end
  end

  defp sync_assignments(directory, access_token, synced_at, service_principal_id) do
    Logger.debug("Streaming app role assignments",
      entra_directory_id: directory.id,
      service_principal_id: service_principal_id
    )

    APIClient.stream_app_role_assignments(access_token, service_principal_id)
    |> Stream.each(fn
      {:error, error} ->
        Logger.debug("Failed to stream app role assignments",
          entra_directory_id: directory.id,
          error: inspect(error)
        )

        raise Entra.SyncError,
          error: error,
          directory_id: directory.id,
          step: :stream_app_role_assignments

      assignments when is_list(assignments) ->
        process_app_role_assignments(directory, access_token, synced_at, assignments)
    end)
    |> Stream.run()
  end

  # Fetches the service principal ID for the specified app type.
  # Returns {:ok, id} on success, {:error, reason} on failure.
  defp fetch_service_principal_id(directory, access_token, app_type) do
    {client_id, app_name} =
      case app_type do
        :directory_sync ->
          {APIClient.client_id(:entra), "Directory Sync"}

        :auth_provider ->
          config = Portal.Config.fetch_env!(:portal, Portal.Entra.AuthProvider)
          {config[:client_id], "Authentication"}
      end

    Logger.debug("Getting service principal for Entra #{app_name} app",
      entra_directory_id: directory.id,
      client_id: client_id
    )

    case APIClient.get_service_principal(access_token, client_id) do
      {:ok, %{body: %{"value" => [%{"id" => id} | _]} = body}} ->
        Logger.debug("Found service principal for #{app_name} app",
          entra_directory_id: directory.id,
          service_principal_id: id,
          response_body: inspect(body)
        )

        {:ok, id}

      {:ok, %{body: body} = response} ->
        Logger.debug("Service principal not found for #{app_name} app",
          entra_directory_id: directory.id,
          client_id: client_id,
          status: response.status,
          response_body: inspect(body)
        )

        {:error, {:not_found, response}}

      {:error, error} ->
        Logger.debug("Failed to get service principal for #{app_name} app",
          entra_directory_id: directory.id,
          error: inspect(error)
        )

        {:error, {:request_failed, error}}
    end
  end

  defp process_app_role_assignments(directory, access_token, synced_at, assignments) do
    Logger.debug("Received app role assignments page",
      entra_directory_id: directory.id,
      count: length(assignments),
      assignments: inspect(assignments, pretty: true, limit: :infinity)
    )

    validate_assignments!(assignments, directory.id)

    # Separate users and groups
    {user_assignments, group_assignments} =
      Enum.split_with(assignments, fn assignment ->
        assignment["principalType"] == "User"
      end)

    Logger.debug("Split assignments by type",
      entra_directory_id: directory.id,
      user_count: length(user_assignments),
      group_count: length(group_assignments)
    )

    sync_direct_user_assignments(directory, access_token, synced_at, user_assignments)
    sync_group_assignments(directory, access_token, synced_at, group_assignments)
  end

  defp validate_assignments!(assignments, directory_id) do
    Enum.each(assignments, fn assignment ->
      unless assignment["principalId"] do
        raise Entra.SyncError,
          error: {:validation, "assignment missing 'principalId' field"},
          directory_id: directory_id,
          step: :process_assignment
      end

      unless assignment["principalType"] do
        raise Entra.SyncError,
          error:
            {:validation,
             "assignment '#{assignment["principalId"]}' missing 'principalType' field"},
          directory_id: directory_id,
          step: :process_assignment
      end

      unless assignment["principalDisplayName"] do
        raise Entra.SyncError,
          error:
            {:validation,
             "assignment '#{assignment["principalId"]}' missing 'principalDisplayName' field"},
          directory_id: directory_id,
          step: :process_assignment
      end
    end)
  end

  defp sync_direct_user_assignments(_directory, _access_token, _synced_at, []), do: :ok

  defp sync_direct_user_assignments(directory, access_token, synced_at, user_assignments) do
    # Build and sync direct user identities
    # Note: appRoleAssignedTo only gives us principalId and principalDisplayName
    # We need to hydrate these with full user details using $batch endpoint
    # Users in groups will get full details from transitiveMembers calls
    Logger.debug("Processing direct user assignments",
      entra_directory_id: directory.id,
      count: length(user_assignments)
    )

    user_ids = Enum.map(user_assignments, & &1["principalId"])

    # Batch fetch users in chunks of 20 (Microsoft Graph $batch API limit)
    direct_identities =
      user_ids
      |> Enum.chunk_every(20)
      |> Enum.flat_map(fn chunk ->
        fetch_user_batch!(directory, access_token, chunk)
      end)

    unless Enum.empty?(direct_identities) do
      batch_upsert_identities(directory, synced_at, direct_identities)
    end
  end

  defp fetch_user_batch!(directory, access_token, chunk) do
    Logger.debug("Fetching batch of users",
      entra_directory_id: directory.id,
      batch_size: length(chunk)
    )

    case APIClient.batch_get_users(access_token, chunk) do
      {:ok, users} when is_list(users) ->
        active_users = Enum.filter(users, &syncable_user?(&1, directory.id))

        Logger.debug("Fetched batch of users successfully",
          entra_directory_id: directory.id,
          fetched_count: length(active_users)
        )

        Enum.map(active_users, fn user ->
          map_user_to_identity(user, directory.id, directory.email_field)
        end)

      {:error, error} ->
        raise Entra.SyncError,
          error: error,
          directory_id: directory.id,
          step: :batch_get_users
    end
  end

  defp sync_group_assignments(_directory, _access_token, _synced_at, []), do: :ok

  defp sync_group_assignments(directory, access_token, synced_at, group_assignments) do
    # Build and sync groups
    groups =
      Enum.map(group_assignments, fn assignment ->
        %{
          idp_id: assignment["principalId"],
          name: assignment["principalDisplayName"]
        }
      end)

    Logger.debug("Upserting groups",
      entra_directory_id: directory.id,
      count: length(groups)
    )

    batch_upsert_groups(directory, synced_at, groups)

    # For each group, stream and sync transitive members
    Enum.each(group_assignments, fn assignment ->
      sync_assigned_group_members(directory, access_token, synced_at, assignment)
    end)
  end

  defp sync_assigned_group_members(directory, access_token, synced_at, assignment) do
    sync_group_members(
      directory,
      access_token,
      synced_at,
      assignment["principalId"],
      assignment["principalDisplayName"]
    )
  end

  defp sync_all_groups(directory, access_token, synced_at) do
    # Stream all groups from the directory
    Logger.debug("Streaming all groups from directory", entra_directory_id: directory.id)

    APIClient.stream_groups(access_token)
    |> Stream.each(fn
      {:error, error} ->
        Logger.debug("Failed to stream groups",
          entra_directory_id: directory.id,
          error: inspect(error)
        )

        raise Entra.SyncError,
          error: error,
          directory_id: directory.id,
          step: :stream_groups

      groups when is_list(groups) ->
        Logger.debug("Received groups page",
          entra_directory_id: directory.id,
          count: length(groups)
        )

        # Validate required fields in groups before processing
        Enum.each(groups, fn group -> validate_group!(group, directory) end)

        # Build and sync groups
        group_attrs =
          Enum.map(groups, fn group ->
            %{
              idp_id: group["id"],
              name: group["displayName"]
            }
          end)

        unless Enum.empty?(group_attrs) do
          Logger.debug("Upserting groups",
            entra_directory_id: directory.id,
            count: length(group_attrs)
          )

          batch_upsert_groups(directory, synced_at, group_attrs)
        end

        # For each group, stream and sync transitive members
        Enum.each(groups, fn group ->
          sync_all_group_members(directory, access_token, synced_at, group)
        end)
    end)
    |> Stream.run()

    :ok
  end

  defp validate_group!(group, directory) do
    unless group["id"] do
      raise Entra.SyncError,
        error: {:validation, "group missing 'id' field"},
        directory_id: directory.id,
        step: :process_group
    end

    unless group["displayName"] do
      raise Entra.SyncError,
        error: {:validation, "group '#{group["id"]}' missing 'displayName' field"},
        directory_id: directory.id,
        step: :process_group
    end
  end

  defp sync_all_group_members(directory, access_token, synced_at, group) do
    sync_group_members(directory, access_token, synced_at, group["id"], group["displayName"])
  end

  defp process_group_members_page(directory, synced_at, group_id, group_name, members) do
    Logger.debug("Received transitive members page",
      entra_directory_id: directory.id,
      group_id: group_id,
      count: length(members)
    )

    # The API client already uses the microsoft.graph.user cast with
    # accountEnabled=true filtering; keep a local guard as a safety net.
    user_members =
      Enum.filter(members, fn member ->
        graph_user_member?(member) and syncable_user?(member, directory.id)
      end)

    # Validate required fields for user members before processing
    Enum.each(user_members, fn member ->
      unless member["id"] do
        raise Entra.SyncError,
          error: {:validation, "user missing 'id' field in group #{group_name}"},
          directory_id: directory.id,
          step: :process_group_member
      end
    end)

    # Build identities for these members
    identities =
      Enum.map(user_members, fn member ->
        map_user_to_identity(member, directory.id, directory.email_field)
      end)

    # Build memberships (group_idp_id, user_idp_id)
    memberships = Enum.map(user_members, fn member -> {group_id, member["id"]} end)

    unless Enum.empty?(identities) do
      batch_upsert_identities(directory, synced_at, identities)
    end

    unless Enum.empty?(memberships) do
      batch_upsert_memberships(directory, synced_at, memberships)
    end
  end

  def batch_upsert_identities(directory, synced_at, identities) do
    account_id = directory.account_id
    issuer = issuer(directory)
    directory_id = directory.id

    case Database.batch_upsert_identities(
           account_id,
           issuer,
           directory_id,
           synced_at,
           identities
         ) do
      {:ok, %{upserted_identities: count}} ->
        Logger.debug("Upserted #{count} identities", entra_directory_id: directory.id)
        :ok

      {:error, reason} ->
        Logger.error("Failed to upsert identities",
          reason: inspect(reason),
          count: length(identities),
          entra_directory_id: directory.id
        )

        raise Entra.SyncError,
          error: {:database, "failed to upsert identities: #{inspect(reason)}"},
          directory_id: directory.id,
          step: :batch_upsert_identities
    end
  end

  def batch_upsert_groups(directory, synced_at, groups) do
    account_id = directory.account_id
    directory_id = directory.id

    {:ok, %{upserted_groups: count}} =
      Database.batch_upsert_groups(account_id, directory_id, synced_at, groups)

    Logger.debug("Upserted #{count} groups", entra_directory_id: directory.id)
    :ok
  end

  defp batch_upsert_memberships(directory, synced_at, memberships) do
    account_id = directory.account_id
    directory_id = directory.id
    issuer = issuer(directory)

    case Database.batch_upsert_memberships(
           account_id,
           issuer,
           directory_id,
           synced_at,
           memberships
         ) do
      {:ok, %{upserted_memberships: count}} ->
        Logger.debug("Upserted #{count} memberships", entra_directory_id: directory.id)
        :ok

      {:error, reason} ->
        Logger.error("Failed to upsert memberships",
          reason: inspect(reason),
          count: length(memberships),
          entra_directory_id: directory.id
        )

        raise Entra.SyncError,
          error: {:database, "failed to upsert memberships: #{inspect(reason)}"},
          directory_id: directory.id,
          step: :batch_upsert_memberships
    end
  end

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
      entra_directory_id: directory.id,
      count: deleted_groups_count
    )

    # Delete identities that weren't synced
    {deleted_identities_count, _} =
      Database.delete_unsynced_identities(account_id, directory_id, synced_at)

    Logger.debug("Deleted unsynced identities",
      entra_directory_id: directory.id,
      count: deleted_identities_count
    )

    # Delete memberships that weren't synced
    {deleted_memberships_count, _} =
      Database.delete_unsynced_memberships(account_id, directory_id, synced_at)

    Logger.debug("Deleted unsynced group memberships",
      entra_directory_id: directory.id,
      count: deleted_memberships_count
    )

    # Delete actors that no longer have any identities and were created by this directory
    {deleted_actors_count, _} =
      Database.delete_actors_without_identities(account_id, directory_id)

    Logger.debug("Deleted actors without identities",
      entra_directory_id: directory.id,
      count: deleted_actors_count
    )
  end

  def syncable_user?(user, directory_id) do
    case Map.fetch(user, "accountEnabled") do
      {:ok, enabled} ->
        enabled != false

      :error ->
        Logger.error("Skipping Entra user with missing accountEnabled field",
          entra_directory_id: directory_id,
          entra_user_id: Map.get(user, "id", "unknown"),
          entra_user_email: Map.get(user, "mail", Map.get(user, "userPrincipalName", "unknown"))
        )

        false
    end
  end

  defp graph_user_member?(member) do
    case Map.get(member, "@odata.type") do
      nil -> true
      "#microsoft.graph.user" -> true
      _ -> false
    end
  end

  def map_user_to_identity(user, directory_id, email_field) do
    unless user["id"] do
      raise Entra.SyncError,
        error: {:validation, "user missing 'id' field"},
        directory_id: directory_id,
        step: :process_user
    end

    primary_email = user[email_field]

    unless Portal.Changeset.valid_email?(primary_email) do
      raise Entra.SyncError,
        error: {:validation, "user '#{user["id"]}' has no valid email in '#{email_field}' field"},
        directory_id: directory_id,
        step: :process_user
    end

    # TODO: Implement separate photo hydration job
    # Profile photos are NOT synced during directory sync because:
    # - Microsoft Graph doesn't provide direct URLs, only binary data via /users/{id}/photo/$value
    # - Would require additional API calls (20 per batch) and storage in Entra blob storage
    # - Should be implemented as a separate background job that:
    #   1. Batches photo requests via $batch endpoint (20 users at a time)
    #   2. Uploads binary data to Entra blob storage
    #   3. Updates identity.firezone_avatar_url with the blob URL
    %{
      idp_id: user["id"],
      email: primary_email,
      name: user["displayName"],
      given_name: user["givenName"],
      family_name: user["surname"],
      preferred_username: user["userPrincipalName"],
      profile: nil
    }
  end

  defmodule Database do
    import Ecto.Query
    alias Portal.DirectorySync
    alias Portal.Safe

    def get_directory(account_id, id) do
      from(d in Entra.Directory,
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

    def batch_upsert_identities(account_id, issuer, directory_id, synced_at, identities) do
      DirectorySync.batch_upsert_identities(
        account_id,
        issuer,
        directory_id,
        synced_at,
        identities,
        [:profile]
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
