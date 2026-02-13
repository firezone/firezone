defmodule Portal.Entra.Sync do
  @moduledoc """
  Oban worker for syncing users, groups, and memberships from Entra ID.
  """
  use Oban.Worker,
    queue: :entra_sync,
    max_attempts: 1,
    unique: [
      period: :infinity,
      states: [:available, :scheduled, :executing],
      keys: [:directory_id]
    ]

  alias Portal.Entra
  alias __MODULE__.Database
  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"directory_id" => directory_id}}) do
    Logger.info("Starting Entra directory sync",
      entra_directory_id: directory_id,
      timestamp: DateTime.utc_now()
    )

    case Database.get_directory(directory_id) do
      nil ->
        Logger.info("Entra directory not found, disabled, or account disabled, skipping",
          entra_directory_id: directory_id
        )

      directory ->
        # Perform the sync
        sync(directory)
    end

    :ok
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
  end

  defp get_access_token!(directory) do
    Logger.debug("Getting access token", entra_directory_id: directory.id)

    case Entra.APIClient.get_access_token(directory.tenant_id) do
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

    Entra.APIClient.stream_app_role_assignments(access_token, service_principal_id)
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
    {config_module, app_name} =
      case app_type do
        :directory_sync -> {Portal.Entra.APIClient, "Directory Sync"}
        :auth_provider -> {Portal.Entra.AuthProvider, "Authentication"}
      end

    config = Portal.Config.fetch_env!(:portal, config_module)
    client_id = config[:client_id]

    Logger.debug("Getting service principal for Entra #{app_name} app",
      entra_directory_id: directory.id,
      client_id: client_id
    )

    case Entra.APIClient.get_service_principal(access_token, client_id) do
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

    case Entra.APIClient.batch_get_users(access_token, chunk) do
      {:ok, users} when is_list(users) ->
        Logger.debug("Fetched batch of users successfully",
          entra_directory_id: directory.id,
          fetched_count: length(users)
        )

        Enum.map(users, fn user -> map_user_to_identity(user, directory.id) end)

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
    group_id = assignment["principalId"]
    group_name = assignment["principalDisplayName"]

    Logger.debug("Streaming transitive members for group",
      entra_directory_id: directory.id,
      group_id: group_id,
      group_name: group_name
    )

    Entra.APIClient.stream_group_transitive_members(access_token, group_id)
    |> Stream.each(fn
      {:error, error} ->
        raise Entra.SyncError,
          error: error,
          directory_id: directory.id,
          step: :stream_group_transitive_members

      members when is_list(members) ->
        process_assigned_group_members_page(directory, synced_at, group_id, group_name, members)
    end)
    |> Stream.run()
  end

  defp process_assigned_group_members_page(directory, synced_at, group_id, group_name, members) do
    Logger.debug("Received transitive members page",
      entra_directory_id: directory.id,
      group_id: group_id,
      count: length(members)
    )

    # Filter only users
    user_members =
      Enum.filter(members, fn member ->
        member["@odata.type"] == "#microsoft.graph.user"
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
      Enum.map(user_members, fn member -> map_user_to_identity(member, directory.id) end)

    # Build memberships (group_idp_id, user_idp_id)
    memberships = Enum.map(user_members, fn member -> {group_id, member["id"]} end)

    unless Enum.empty?(identities) do
      batch_upsert_identities(directory, synced_at, identities)
    end

    unless Enum.empty?(memberships) do
      batch_upsert_memberships(directory, synced_at, memberships)
    end
  end

  defp sync_all_groups(directory, access_token, synced_at) do
    # Stream all groups from the directory
    Logger.debug("Streaming all groups from directory", entra_directory_id: directory.id)

    Entra.APIClient.stream_groups(access_token)
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
        Enum.each(groups, fn group ->
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
        end)

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

  defp sync_all_group_members(directory, access_token, synced_at, group) do
    group_id = group["id"]
    group_name = group["displayName"]

    Logger.debug("Streaming transitive members for group",
      entra_directory_id: directory.id,
      group_id: group_id,
      group_name: group_name
    )

    Entra.APIClient.stream_group_transitive_members(access_token, group_id)
    |> Stream.each(fn
      {:error, error} ->
        raise Entra.SyncError,
          error: error,
          directory_id: directory.id,
          step: :stream_group_transitive_members

      members when is_list(members) ->
        process_all_group_members_page(directory, synced_at, group_id, group_name, members)
    end)
    |> Stream.run()
  end

  defp process_all_group_members_page(directory, synced_at, group_id, group_name, members) do
    Logger.debug("Received transitive members page",
      entra_directory_id: directory.id,
      group_id: group_id,
      count: length(members)
    )

    # Filter only users
    user_members =
      Enum.filter(members, fn member ->
        member["@odata.type"] == "#microsoft.graph.user"
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
      Enum.map(user_members, fn member -> map_user_to_identity(member, directory.id) end)

    # Build memberships (group_idp_id, user_idp_id)
    memberships = Enum.map(user_members, fn member -> {group_id, member["id"]} end)

    unless Enum.empty?(identities) do
      batch_upsert_identities(directory, synced_at, identities)
    end

    unless Enum.empty?(memberships) do
      batch_upsert_memberships(directory, synced_at, memberships)
    end
  end

  defp batch_upsert_identities(directory, synced_at, identities) do
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

        :error
    end
  end

  defp batch_upsert_groups(directory, synced_at, groups) do
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

        :error
    end
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

  defp map_user_to_identity(user, directory_id) do
    # Map Microsoft Graph user fields to our identity schema
    # Note: 'mail' is the primary email, userPrincipalName is the UPN (user@domain.com)
    # We prefer 'mail' but fall back to userPrincipalName if mail is null
    #
    # Validate that critical fields are present
    unless user["id"] do
      raise Entra.SyncError,
        error: {:validation, "user missing 'id' field"},
        directory_id: directory_id,
        step: :process_user
    end

    primary_email = user["mail"] || user["userPrincipalName"]

    unless primary_email do
      raise Entra.SyncError,
        error: {:validation, "user '#{user["id"]}' missing 'mail' field"},
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
      profile: user["aboutMe"]
    }
  end

  defmodule Database do
    import Ecto.Query
    alias Portal.Safe

    def get_directory(id) do
      from(d in Entra.Directory,
        join: a in Portal.Account,
        on: a.id == d.account_id,
        where: d.id == ^id,
        where: d.is_disabled == false,
        where: is_nil(a.disabled_at)
      )
      |> Safe.unscoped()
      |> Safe.one()
    end

    def update_directory(changeset) do
      changeset |> Safe.unscoped() |> Safe.update()
    end

    def batch_upsert_identities(
          _account_id,
          _issuer,
          _directory_id,
          _last_synced_at,
          []
        ),
        do: {:ok, %{upserted_identities: 0}}

    def batch_upsert_identities(
          account_id,
          issuer,
          directory_id,
          last_synced_at,
          identity_attrs
        ) do
      query = build_identity_upsert_query(length(identity_attrs))

      params =
        build_identity_upsert_params(
          account_id,
          issuer,
          directory_id,
          last_synced_at,
          identity_attrs
        )

      case Safe.unscoped() |> Safe.query(query, params) do
        {:ok, %Postgrex.Result{rows: rows}} ->
          {:ok, %{upserted_identities: length(rows)}}

        {:error, reason} ->
          {:error, reason}
      end
    end

    defp build_identity_upsert_query(count) do
      # Each identity has 7 fields: idp_id, email, name, given_name, family_name, preferred_username, profile
      values_clause =
        for i <- 1..count, base = (i - 1) * 7 do
          "($#{base + 1}, $#{base + 2}, $#{base + 3}, $#{base + 4}, $#{base + 5}, $#{base + 6}, $#{base + 7})"
        end
        |> Enum.join(", ")

      offset = count * 7
      account_id = offset + 1
      issuer = offset + 2
      directory_id = offset + 3
      last_synced_at = offset + 4

      """
      WITH input_data AS (
        SELECT * FROM (VALUES #{values_clause})
        AS t(idp_id, email, name, given_name, family_name, preferred_username, profile)
      ),
      existing_identities AS (
        SELECT ei.id, ei.actor_id, ei.idp_id
        FROM external_identities ei
        WHERE ei.account_id = $#{account_id}
          AND ei.issuer = $#{issuer}
          AND ei.idp_id IN (SELECT idp_id FROM input_data)
      ),
      existing_actors_by_email AS (
        SELECT DISTINCT ON (id.idp_id) a.id AS actor_id, id.idp_id
        FROM input_data id
        JOIN actors a ON a.email = id.email AND a.account_id = $#{account_id}
        WHERE id.idp_id NOT IN (SELECT idp_id FROM existing_identities)
          AND id.email IS NOT NULL
        ORDER BY id.idp_id, a.inserted_at ASC
      ),
      actors_to_create AS (
        SELECT
          uuid_generate_v4() AS new_actor_id,
          id.idp_id,
          id.name,
          id.email
        FROM input_data id
        WHERE id.idp_id NOT IN (SELECT idp_id FROM existing_identities)
          AND id.idp_id NOT IN (SELECT idp_id FROM existing_actors_by_email)
      ),
      new_actors AS (
        INSERT INTO actors (id, type, account_id, name, email, created_by_directory_id, inserted_at, updated_at)
        SELECT
          new_actor_id,
          'account_user',
          $#{account_id},
          name,
          email,
          $#{directory_id},
          $#{last_synced_at},
          $#{last_synced_at}
        FROM actors_to_create
        RETURNING id, name
      ),
      all_actor_mappings AS (
        SELECT atc.new_actor_id AS actor_id, atc.idp_id, id.email, id.name, id.given_name, id.family_name, id.preferred_username, id.profile
        FROM actors_to_create atc
        JOIN input_data id ON id.idp_id = atc.idp_id
        UNION ALL
        SELECT ei.actor_id, ei.idp_id, id.email, id.name, id.given_name, id.family_name, id.preferred_username, id.profile
        FROM existing_identities ei
        JOIN input_data id ON id.idp_id = ei.idp_id
        UNION ALL
        SELECT eabe.actor_id, eabe.idp_id, id.email, id.name, id.given_name, id.family_name, id.preferred_username, id.profile
        FROM existing_actors_by_email eabe
        JOIN input_data id ON id.idp_id = eabe.idp_id
      )
      INSERT INTO external_identities (
        id, actor_id, issuer, idp_id, directory_id, email, name, given_name, family_name, preferred_username, profile,
        last_synced_at, account_id, inserted_at, updated_at
      )
      SELECT
        COALESCE(ei.id, uuid_generate_v4()),
        aam.actor_id,
        $#{issuer},
        aam.idp_id,
        $#{directory_id},
        aam.email,
        aam.name,
        aam.given_name,
        aam.family_name,
        aam.preferred_username,
        aam.profile,
        $#{last_synced_at},
        $#{account_id},
        $#{last_synced_at},
        $#{last_synced_at}
      FROM all_actor_mappings aam
      LEFT JOIN existing_identities ei ON ei.idp_id = aam.idp_id
      ON CONFLICT (account_id, idp_id, issuer)
      DO UPDATE SET
        directory_id = EXCLUDED.directory_id,
        email = EXCLUDED.email,
        name = EXCLUDED.name,
        given_name = EXCLUDED.given_name,
        family_name = EXCLUDED.family_name,
        preferred_username = EXCLUDED.preferred_username,
        profile = EXCLUDED.profile,
        last_synced_at = EXCLUDED.last_synced_at,
        updated_at = EXCLUDED.updated_at
      WHERE external_identities.last_synced_at IS NULL
        OR external_identities.last_synced_at < EXCLUDED.last_synced_at
      RETURNING 1
      """
    end

    defp build_identity_upsert_params(
           account_id,
           issuer,
           directory_id,
           last_synced_at,
           attrs
         ) do
      params =
        Enum.flat_map(attrs, fn a ->
          [
            a.idp_id,
            a.email,
            a.name,
            Map.get(a, :given_name),
            Map.get(a, :family_name),
            Map.get(a, :preferred_username),
            Map.get(a, :profile)
          ]
        end)

      params ++
        [
          Ecto.UUID.dump!(account_id),
          issuer,
          Ecto.UUID.dump!(directory_id),
          last_synced_at
        ]
    end

    def batch_upsert_groups(_account_id, _directory_id, _last_synced_at, []),
      do: {:ok, %{upserted_groups: 0}}

    def batch_upsert_groups(account_id, directory_id, last_synced_at, group_attrs) do
      # Convert to raw SQL to support conditional updates based on last_synced_at
      query = build_group_upsert_query(length(group_attrs))

      params = build_group_upsert_params(account_id, directory_id, last_synced_at, group_attrs)

      case Safe.unscoped() |> Safe.query(query, params) do
        {:ok, %Postgrex.Result{num_rows: num_rows}} ->
          {:ok, %{upserted_groups: num_rows}}

        {:error, reason} ->
          {:error, reason}
      end
    end

    defp build_group_upsert_query(count) do
      # Each group has 2 fields: idp_id, name
      values_clause =
        for i <- 1..count, base = (i - 1) * 2 do
          "($#{base + 1}, $#{base + 2})"
        end
        |> Enum.join(", ")

      offset = count * 2
      account_id = offset + 1
      directory_id = offset + 2
      last_synced_at = offset + 3

      """
      WITH input_data (idp_id, name) AS (
        VALUES #{values_clause}
      )
      INSERT INTO groups (
        id, name, directory_id, idp_id, account_id,
        inserted_at, updated_at, type, last_synced_at
      )
      SELECT
        uuid_generate_v4(),
        id.name,
        $#{directory_id},
        id.idp_id,
        $#{account_id},
        $#{last_synced_at},
        $#{last_synced_at},
        'static',
        $#{last_synced_at}
      FROM input_data id
      ON CONFLICT (account_id, idp_id) WHERE idp_id IS NOT NULL
      DO UPDATE SET
        name = CASE
          WHEN groups.last_synced_at IS NULL OR groups.last_synced_at < EXCLUDED.last_synced_at
          THEN EXCLUDED.name
          ELSE groups.name
        END,
        directory_id = CASE
          WHEN groups.last_synced_at IS NULL OR groups.last_synced_at < EXCLUDED.last_synced_at
          THEN EXCLUDED.directory_id
          ELSE groups.directory_id
        END,
        last_synced_at = CASE
          WHEN groups.last_synced_at IS NULL OR groups.last_synced_at < EXCLUDED.last_synced_at
          THEN EXCLUDED.last_synced_at
          ELSE groups.last_synced_at
        END,
        updated_at = CASE
          WHEN groups.last_synced_at IS NULL OR groups.last_synced_at < EXCLUDED.last_synced_at
          THEN EXCLUDED.updated_at
          ELSE groups.updated_at
        END
      """
    end

    defp build_group_upsert_params(account_id, directory_id, last_synced_at, group_attrs) do
      group_params =
        group_attrs
        |> Enum.flat_map(fn attrs ->
          [attrs.idp_id, attrs.name]
        end)

      # Properly cast UUIDs to binary
      group_params ++
        [
          Ecto.UUID.dump!(account_id),
          Ecto.UUID.dump!(directory_id),
          last_synced_at
        ]
    end

    def batch_upsert_memberships(_account_id, _issuer, _directory_id, _last_synced_at, []),
      do: {:ok, %{upserted_memberships: 0}}

    def batch_upsert_memberships(account_id, issuer, directory_id, last_synced_at, tuples) do
      query = build_membership_upsert_query(length(tuples))

      params =
        build_membership_upsert_params(account_id, issuer, directory_id, last_synced_at, tuples)

      case Safe.unscoped() |> Safe.query(query, params) do
        {:ok, %Postgrex.Result{num_rows: num_rows}} -> {:ok, %{upserted_memberships: num_rows}}
        {:error, reason} -> {:error, reason}
      end
    end

    defp build_membership_upsert_query(count) do
      values_clause =
        for i <- 1..count, base = (i - 1) * 2 do
          "($#{base + 1}, $#{base + 2})"
        end
        |> Enum.join(", ")

      offset = count * 2
      account_id = offset + 1
      issuer = offset + 2
      last_synced_at = offset + 3

      """
      WITH membership_input AS (
        SELECT * FROM (VALUES #{values_clause})
        AS t(group_idp_id, user_idp_id)
      ),
      resolved_memberships AS (
        SELECT
          ei.actor_id,
          ag.id as group_id
        FROM membership_input mi
        JOIN external_identities ei ON (
          ei.idp_id = mi.user_idp_id
          AND ei.account_id = $#{account_id}
          AND ei.issuer = $#{issuer}
        )
        JOIN groups ag ON (
          ag.idp_id = mi.group_idp_id
          AND ag.account_id = $#{account_id}
        )
      )
      INSERT INTO memberships (id, actor_id, group_id, account_id, last_synced_at)
      SELECT
        uuid_generate_v4(),
        rm.actor_id,
        rm.group_id,
        $#{account_id} AS account_id,
        $#{last_synced_at} AS last_synced_at
      FROM resolved_memberships rm
      ON CONFLICT (actor_id, group_id) DO UPDATE SET
        last_synced_at = EXCLUDED.last_synced_at
      WHERE memberships.last_synced_at IS NULL
        OR memberships.last_synced_at < EXCLUDED.last_synced_at
      RETURNING 1
      """
    end

    defp build_membership_upsert_params(account_id, issuer, _directory_id, last_synced_at, tuples) do
      params =
        Enum.flat_map(tuples, fn {group_idp_id, user_idp_id} ->
          [group_idp_id, user_idp_id]
        end)

      params ++ [Ecto.UUID.dump!(account_id), issuer, last_synced_at]
    end

    def delete_unsynced_groups(account_id, directory_id, synced_at) do
      query =
        from(g in Portal.Group,
          where: g.account_id == ^account_id,
          where: g.directory_id == ^directory_id,
          where: g.last_synced_at < ^synced_at or is_nil(g.last_synced_at)
        )

      query |> Safe.unscoped() |> Safe.delete_all()
    end

    def delete_unsynced_identities(account_id, directory_id, synced_at) do
      query =
        from(i in Portal.ExternalIdentity,
          where: i.account_id == ^account_id,
          where: i.directory_id == ^directory_id,
          where: i.last_synced_at < ^synced_at or is_nil(i.last_synced_at)
        )

      query |> Safe.unscoped() |> Safe.delete_all()
    end

    def delete_unsynced_memberships(account_id, directory_id, synced_at) do
      # Delete memberships for groups in this directory that haven't been synced
      query =
        from(m in Portal.Membership,
          join: g in Portal.Group,
          on: m.group_id == g.id,
          where: g.account_id == ^account_id,
          where: g.directory_id == ^directory_id,
          where: m.last_synced_at < ^synced_at or is_nil(m.last_synced_at)
        )

      query |> Safe.unscoped() |> Safe.delete_all()
    end

    def delete_actors_without_identities(account_id, directory_id) do
      # Delete actors that no longer have any identities
      # This cleans up actors whose identities were deleted in the previous step
      # Only delete actors created by this specific directory
      query =
        from(a in Portal.Actor,
          where: a.account_id == ^account_id,
          where: a.created_by_directory_id == ^directory_id,
          where:
            fragment(
              "NOT EXISTS (SELECT 1 FROM external_identities WHERE actor_id = ?)",
              a.id
            )
        )

      query |> Safe.unscoped() |> Safe.delete_all()
    end
  end

  defp issuer(directory), do: "https://login.microsoftonline.com/#{directory.tenant_id}/v2.0"
end
