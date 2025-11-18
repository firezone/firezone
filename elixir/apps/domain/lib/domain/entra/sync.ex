defmodule Domain.Entra.Sync do
  @moduledoc """
  Oban worker for syncing users, groups, and memberships from Entra ID.
  """
  # Retries and uniqueness are handled by the scheduler
  use Oban.Worker,
    queue: :entra_sync,
    max_attempts: 1

  alias Domain.{Safe, Entra}
  alias __MODULE__.Query
  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{id: job_id, args: %{"directory_id" => directory_id}}) do
    Logger.info("Starting Entra directory sync",
      entra_directory_id: directory_id,
      timestamp: DateTime.utc_now()
    )

    case Safe.unscoped() |> Safe.one(Query.get_directory(directory_id)) do
      nil ->
        Logger.info("Entra directory deleted or sync disabled, skipping",
          entra_directory_id: directory_id
        )

      directory ->
        # Set current job ID to signify sync in progress and provide a handle for cancellation
        update(directory, %{"current_job_id" => job_id})

        # Perform the sync
        sync(directory)

        # Release the current job ID
        update(directory, %{"current_job_id" => nil})
    end

    :ok
  end

  defp update(directory, attrs) do
    changeset = Ecto.Changeset.cast(directory, attrs, [:current_job_id, :synced_at])
    {:ok, _directory} = Safe.update(Safe.unscoped(), changeset)
  end

  defp sync(%Entra.Directory{} = directory) do
    access_token = get_access_token!(directory)
    synced_at = DateTime.utc_now()

    fetch_and_sync_all(directory, access_token, synced_at)
    delete_unsynced(directory, synced_at)
    update(directory, %{"synced_at" => synced_at})

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
          reason: "Invalid access token response",
          cause: response,
          directory_id: directory.id,
          step: :get_access_token

      {:error, error} ->
        Logger.debug("Failed to get access token",
          entra_directory_id: directory.id,
          error: inspect(error)
        )

        raise Entra.SyncError,
          reason: "Failed to get access token",
          cause: error,
          directory_id: directory.id,
          step: :get_access_token
    end
  end

  defp fetch_and_sync_all(directory, access_token, synced_at) do
    # Get the service principal ID for this app
    config = Domain.Config.fetch_env!(:domain, Entra.APIClient)
    client_id = config[:client_id]

    Logger.debug("Getting service principal",
      entra_directory_id: directory.id,
      client_id: client_id
    )

    service_principal_id =
      case Entra.APIClient.get_service_principal(access_token, client_id) do
        {:ok, %{body: %{"value" => [%{"id" => id} | _]} = body}} ->
          Logger.debug("Found service principal",
            entra_directory_id: directory.id,
            service_principal_id: id,
            response_body: inspect(body)
          )

          id

        {:ok, %{body: body} = response} ->
          Logger.debug("Service principal not found",
            entra_directory_id: directory.id,
            client_id: client_id,
            status: response.status,
            response_body: inspect(body)
          )

          raise Entra.SyncError,
            reason: "Service principal not found",
            cause: response,
            directory_id: directory.id,
            step: :get_service_principal

        {:error, error} ->
          Logger.debug("Failed to get service principal",
            entra_directory_id: directory.id,
            error: inspect(error)
          )

          raise Entra.SyncError,
            reason: "Failed to get service principal",
            cause: error,
            directory_id: directory.id,
            step: :get_service_principal
      end

    # Stream and sync app role assignments page by page
    Logger.debug("Streaming app role assignments", entra_directory_id: directory.id)

    Entra.APIClient.stream_app_role_assignments(access_token, service_principal_id)
    |> Stream.each(fn
      {:error, error} ->
        Logger.debug("Failed to stream app role assignments",
          entra_directory_id: directory.id,
          error: inspect(error)
        )

        raise Entra.SyncError,
          reason: "Failed to stream app role assignments",
          cause: error,
          directory_id: directory.id,
          step: :stream_app_role_assignments

      assignments when is_list(assignments) ->
        Logger.debug("Received app role assignments page",
          entra_directory_id: directory.id,
          count: length(assignments),
          assignments: inspect(assignments, pretty: true, limit: :infinity)
        )

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

        # Build and sync direct user identities
        # Note: appRoleAssignedTo only gives us principalId and principalDisplayName
        # We need to hydrate these with full user details using $batch endpoint
        # Users in groups will get full details from transitiveMembers calls
        unless Enum.empty?(user_assignments) do
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

                  Enum.map(users, &map_user_to_identity/1)

                {:error, reason} ->
                  Logger.warning("Failed to fetch batch of users",
                    user_ids: chunk,
                    reason: inspect(reason),
                    entra_directory_id: directory.id
                  )

                  []
              end
            end)

          unless Enum.empty?(direct_identities) do
            batch_upsert_identities(directory, synced_at, direct_identities)
          end
        end

        # Build and sync groups
        groups =
          Enum.map(group_assignments, fn assignment ->
            %{
              idp_id: assignment["principalId"],
              name: assignment["principalDisplayName"]
            }
          end)

        unless Enum.empty?(groups) do
          Logger.debug("Upserting groups",
            entra_directory_id: directory.id,
            count: length(groups)
          )

          batch_upsert_groups(directory, synced_at, groups)
        end

        # For each group, stream and sync transitive members
        Enum.each(group_assignments, fn assignment ->
          group_id = assignment["principalId"]
          group_name = assignment["principalDisplayName"]

          Logger.debug("Streaming transitive members for group",
            entra_directory_id: directory.id,
            group_id: group_id,
            group_name: group_name
          )

          Entra.APIClient.stream_group_transitive_members(access_token, group_id)
          |> Stream.each(fn
            {:error, reason} ->
              Logger.debug("Failed to fetch transitive members for group",
                group_id: group_id,
                reason: inspect(reason),
                entra_directory_id: directory.id
              )

            members when is_list(members) ->
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

              # Build identities for these members
              identities = Enum.map(user_members, &map_user_to_identity/1)

              # Build memberships (group_idp_id, user_idp_id)
              memberships =
                Enum.map(user_members, fn member ->
                  {group_id, member["id"]}
                end)

              unless Enum.empty?(identities) do
                batch_upsert_identities(directory, synced_at, identities)
              end

              unless Enum.empty?(memberships) do
                batch_upsert_memberships(directory, synced_at, memberships)
              end
          end)
          |> Stream.run()
        end)
    end)
    |> Stream.run()

    :ok
  end

  defp batch_upsert_identities(directory, synced_at, identities) do
    account_id = directory.account_id
    issuer = issuer(directory)

    case Query.batch_upsert_identities(account_id, issuer, synced_at, identities) do
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
    tenant_id = directory.tenant_id

    {:ok, %{upserted_groups: count}} =
      Query.batch_upsert_groups(account_id, synced_at, tenant_id, groups)

    Logger.debug("Upserted #{count} groups", entra_directory_id: directory.id)
    :ok
  end

  defp batch_upsert_memberships(directory, synced_at, memberships) do
    account_id = directory.account_id
    tenant_id = directory.tenant_id
    issuer = issuer(directory)

    case Query.batch_upsert_memberships(account_id, issuer, synced_at, tenant_id, memberships) do
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
    tenant_id = directory.tenant_id
    issuer = issuer(directory)

    # Delete groups that weren't synced
    {deleted_groups_count, _} = Query.delete_unsynced_groups(account_id, tenant_id, synced_at)

    Logger.debug("Deleted unsynced groups",
      entra_directory_id: directory.id,
      count: deleted_groups_count
    )

    # Delete identities that weren't synced
    {deleted_identities_count, _} =
      Query.delete_unsynced_identities(account_id, issuer, synced_at)

    Logger.debug("Deleted unsynced identities",
      entra_directory_id: directory.id,
      count: deleted_identities_count
    )

    # Delete memberships that weren't synced
    {deleted_memberships_count, _} =
      Query.delete_unsynced_memberships(account_id, tenant_id, synced_at)

    Logger.debug("Deleted unsynced group memberships",
      entra_directory_id: directory.id,
      count: deleted_memberships_count
    )

    # Delete actors that no longer have any identities
    {deleted_actors_count, _} = Query.delete_actors_without_identities(account_id)

    Logger.debug("Deleted actors without identities",
      entra_directory_id: directory.id,
      count: deleted_actors_count
    )
  end

  defp map_user_to_identity(user) do
    # Map Microsoft Graph user fields to our identity schema
    # Note: 'mail' is the primary email, userPrincipalName is the UPN (user@domain.com)
    # We prefer 'mail' but fall back to userPrincipalName if mail is null
    #
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
      email: user["mail"] || user["userPrincipalName"],
      name: user["displayName"],
      given_name: user["givenName"],
      family_name: user["surname"],
      preferred_username: user["userPrincipalName"]
    }
  end

  defmodule Query do
    import Ecto.Query
    alias Domain.Safe

    def get_directory(id) do
      from(d in Entra.Directory, as: :directories)
      |> where([directories: d], d.id == ^id)
      |> where([directories: d], d.is_disabled == false)
    end

    def batch_upsert_identities(_account_id, _issuer, _last_synced_at, []),
      do: {:ok, %{upserted_identities: 0}}

    def batch_upsert_identities(account_id, issuer, last_synced_at, identity_attrs) do
      query = build_identity_upsert_query(length(identity_attrs))
      params = build_identity_upsert_params(account_id, issuer, last_synced_at, identity_attrs)

      case Safe.unscoped() |> Safe.query(query, params) do
        {:ok, %Postgrex.Result{rows: rows}} -> {:ok, %{upserted_identities: length(rows)}}
        {:error, reason} -> {:error, reason}
      end
    end

    defp build_identity_upsert_query(count) do
      # Each identity has 6 fields: idp_id, email, name, given_name, family_name, preferred_username
      values_clause =
        for i <- 1..count, base = (i - 1) * 6 do
          "($#{base + 1}, $#{base + 2}, $#{base + 3}, $#{base + 4}, $#{base + 5}, $#{base + 6})"
        end
        |> Enum.join(", ")

      offset = count * 6
      account_id = offset + 1
      issuer = offset + 2
      last_synced_at = offset + 3

      """
      WITH input_data AS (
        SELECT * FROM (VALUES #{values_clause})
        AS t(idp_id, email, name, given_name, family_name, preferred_username)
      ),
      existing_identities AS (
        SELECT ai.id, ai.actor_id, ai.idp_id
        FROM auth_identities ai
        WHERE ai.account_id = $#{account_id}
          AND ai.issuer = $#{issuer}
          AND ai.idp_id IN (SELECT idp_id FROM input_data)
      ),
      actors_to_create AS (
        SELECT
          uuid_generate_v4() AS new_actor_id,
          id.idp_id,
          id.name
        FROM input_data id
        WHERE id.idp_id NOT IN (
          SELECT idp_id FROM existing_identities
        )
      ),
      new_actors AS (
        INSERT INTO actors (id, type, account_id, name, last_synced_at, created_by, created_by_subject, inserted_at, updated_at)
        SELECT
          new_actor_id,
          'account_user',
          $#{account_id},
          name,
          $#{last_synced_at},
          'system',
          jsonb_build_object('name', 'System', 'email', null),
          $#{last_synced_at},
          $#{last_synced_at}
        FROM actors_to_create
        RETURNING id, name
      ),
      updated_actors AS (
        UPDATE actors
        SET name = id.name, last_synced_at = $#{last_synced_at}, updated_at = $#{last_synced_at}
        FROM input_data id
        JOIN existing_identities ei ON ei.idp_id = id.idp_id
        WHERE actors.id = ei.actor_id
        RETURNING actors.id
      ),
      all_actor_mappings AS (
        SELECT atc.new_actor_id AS actor_id, atc.idp_id, id.email, id.name, id.given_name, id.family_name, id.preferred_username
        FROM actors_to_create atc
        JOIN input_data id ON id.idp_id = atc.idp_id
        UNION ALL
        SELECT ei.actor_id, ei.idp_id, id.email, id.name, id.given_name, id.family_name, id.preferred_username
        FROM existing_identities ei
        JOIN input_data id ON id.idp_id = ei.idp_id
      )
      INSERT INTO auth_identities (
        id, actor_id, issuer, idp_id, email, name, given_name, family_name, preferred_username,
        last_synced_at, account_id, created_by, inserted_at, created_by_subject
      )
      SELECT
        COALESCE(ei.id, uuid_generate_v4()),
        aam.actor_id,
        $#{issuer},
        aam.idp_id,
        aam.email,
        aam.name,
        aam.given_name,
        aam.family_name,
        aam.preferred_username,
        $#{last_synced_at},
        $#{account_id},
        'system',
        $#{last_synced_at},
        jsonb_build_object('name', 'System', 'email', null)
      FROM all_actor_mappings aam
      LEFT JOIN existing_identities ei ON ei.idp_id = aam.idp_id
      ON CONFLICT (account_id, issuer, idp_id) WHERE (issuer IS NOT NULL OR idp_id IS NOT NULL)
      DO UPDATE SET
        email = EXCLUDED.email,
        name = EXCLUDED.name,
        given_name = EXCLUDED.given_name,
        family_name = EXCLUDED.family_name,
        preferred_username = EXCLUDED.preferred_username,
        last_synced_at = EXCLUDED.last_synced_at
      RETURNING 1
      """
    end

    defp build_identity_upsert_params(account_id, issuer, last_synced_at, attrs) do
      params =
        Enum.flat_map(attrs, fn a ->
          [
            a.idp_id,
            a.email,
            a.name,
            Map.get(a, :given_name),
            Map.get(a, :family_name),
            Map.get(a, :preferred_username)
          ]
        end)

      params ++ [Ecto.UUID.dump!(account_id), issuer, last_synced_at]
    end

    def batch_upsert_groups(_account_id, _last_synced_at, _tenant_id, []),
      do: {:ok, %{upserted_groups: 0}}

    def batch_upsert_groups(account_id, last_synced_at, tenant_id, group_attrs) do
      directory = "entra:#{tenant_id}"

      values =
        Enum.map(group_attrs, fn attrs ->
          %{
            id: Ecto.UUID.generate(),
            name: attrs.name,
            directory: directory,
            idp_id: attrs.idp_id,
            account_id: account_id,
            inserted_at: last_synced_at,
            updated_at: last_synced_at,
            created_by: :system,
            type: :static,
            created_by_subject: %{"name" => "System", "email" => nil},
            last_synced_at: last_synced_at
          }
        end)

      {count, _} =
        Safe.unscoped()
        |> Safe.insert_all(Domain.Actors.Group, values,
          on_conflict: {:replace, [:name, :last_synced_at, :updated_at]},
          conflict_target:
            {:unsafe_fragment,
             ~s/(account_id, directory, idp_id) WHERE directory IS NOT NULL and idp_id IS NOT NULL/},
          returning: false
        )

      {:ok, %{upserted_groups: count}}
    end

    def batch_upsert_memberships(_account_id, _issuer, _last_synced_at, _tenant_id, []),
      do: {:ok, %{upserted_memberships: 0}}

    def batch_upsert_memberships(account_id, issuer, last_synced_at, tenant_id, tuples) do
      query = build_membership_upsert_query(length(tuples))

      params =
        build_membership_upsert_params(account_id, issuer, last_synced_at, tenant_id, tuples)

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
      directory = offset + 4

      """
      WITH membership_input AS (
        SELECT * FROM (VALUES #{values_clause})
        AS t(group_idp_id, user_idp_id)
      ),
      resolved_memberships AS (
        SELECT
          ai.actor_id,
          ag.id as group_id
        FROM membership_input mi
        JOIN auth_identities ai ON (
          ai.idp_id = mi.user_idp_id
          AND ai.account_id = $#{account_id}
          AND ai.issuer = $#{issuer}
        )
        JOIN actor_groups ag ON (
          ag.idp_id = mi.group_idp_id
          AND ag.directory = $#{directory}
          AND ag.account_id = $#{account_id}
        )
      )
      INSERT INTO actor_group_memberships (id, actor_id, group_id, account_id, last_synced_at)
      SELECT
        uuid_generate_v4(),
        rm.actor_id,
        rm.group_id,
        $#{account_id} AS account_id,
        $#{last_synced_at} AS last_synced_at
      FROM resolved_memberships rm
      ON CONFLICT (actor_id, group_id) DO UPDATE SET
        last_synced_at = EXCLUDED.last_synced_at
      RETURNING 1
      """
    end

    defp build_membership_upsert_params(account_id, issuer, last_synced_at, tenant_id, tuples) do
      directory = "entra:#{tenant_id}"

      params =
        Enum.flat_map(tuples, fn {group_idp_id, user_idp_id} ->
          [group_idp_id, user_idp_id]
        end)

      params ++ [Ecto.UUID.dump!(account_id), issuer, last_synced_at, directory]
    end

    def delete_unsynced_groups(account_id, tenant_id, synced_at) do
      directory = "entra:#{tenant_id}"

      query =
        from(g in Domain.Actors.Group,
          where: g.account_id == ^account_id,
          where: g.directory == ^directory,
          where: g.last_synced_at != ^synced_at or is_nil(g.last_synced_at)
        )

      Safe.delete_all(Safe.unscoped(), query)
    end

    def delete_unsynced_identities(account_id, issuer, synced_at) do
      query =
        from(i in Domain.Auth.Identity,
          where: i.account_id == ^account_id,
          where: i.issuer == ^issuer,
          where: i.last_synced_at != ^synced_at or is_nil(i.last_synced_at)
        )

      Safe.delete_all(Safe.unscoped(), query)
    end

    def delete_unsynced_memberships(account_id, tenant_id, synced_at) do
      directory = "entra:#{tenant_id}"

      # Delete memberships for groups in this directory that haven't been synced
      query =
        from(m in Domain.Actors.Membership,
          join: g in Domain.Actors.Group,
          on: m.group_id == g.id,
          where: g.account_id == ^account_id,
          where: g.directory == ^directory,
          where: m.last_synced_at != ^synced_at or is_nil(m.last_synced_at)
        )

      Safe.delete_all(Safe.unscoped(), query)
    end

    def delete_actors_without_identities(account_id) do
      # Delete actors that no longer have any identities
      # This cleans up actors whose identities were deleted in the previous step
      # Only delete actors created by the system (directory sync), not user-created actors
      # Check for created_by_subject with name='System' and email=null
      # Note: PostgreSQL doesn't support LEFT JOIN in DELETE, so we use a subquery
      query =
        from(a in Domain.Actors.Actor,
          where: a.account_id == ^account_id,
          where: a.type == :account_user,
          where: a.created_by == :system,
          where:
            fragment(
              "? = ?",
              a.created_by_subject,
              ^%{"name" => "System", "email" => nil}
            ),
          where:
            fragment(
              "NOT EXISTS (SELECT 1 FROM auth_identities WHERE actor_id = ?)",
              a.id
            )
        )

      Safe.delete_all(Safe.unscoped(), query)
    end
  end

  defp issuer(directory), do: "https://login.microsoftonline.com/#{directory.tenant_id}/v2.0"
end
