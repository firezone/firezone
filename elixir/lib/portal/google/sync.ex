defmodule Portal.Google.Sync do
  @moduledoc """
  Oban worker for syncing users, groups, and memberships from Google Workspace.
  """
  use Oban.Worker,
    queue: :google_sync,
    max_attempts: 1,
    unique: [
      period: :infinity,
      states: [:available, :scheduled, :executing],
      keys: [:directory_id]
    ]

  alias Portal.Google
  alias __MODULE__.Database
  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"directory_id" => directory_id}}) do
    Logger.info("Starting Google directory sync",
      google_directory_id: directory_id,
      timestamp: DateTime.utc_now()
    )

    case Database.get_directory(directory_id) do
      nil ->
        Logger.info("Google directory not found, disabled, or account disabled, skipping",
          google_directory_id: directory_id
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

  defp sync(%Google.Directory{} = directory) do
    access_token = get_access_token!(directory)
    synced_at = DateTime.utc_now()

    fetch_and_sync_all(directory, access_token, synced_at)
    delete_unsynced(directory, synced_at)

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

    Logger.info("Finished Google directory sync in #{duration} seconds",
      google_directory_id: directory.id
    )
  end

  defp get_access_token!(directory) do
    Logger.debug("Getting access token", google_directory_id: directory.id)
    key = service_account_key(directory)

    case Google.APIClient.get_access_token(directory.impersonation_email, key) do
      {:ok, %{body: %{"access_token" => access_token}}} ->
        Logger.debug("Successfully obtained access token", google_directory_id: directory.id)
        access_token

      {:ok, response} ->
        Logger.debug("Invalid access token response",
          google_directory_id: directory.id,
          status: response.status,
          body: inspect(response.body)
        )

        raise Google.SyncError,
          reason: "Invalid access token response",
          cause: response,
          directory_id: directory.id,
          step: :get_access_token

      {:error, error} ->
        Logger.debug("Failed to get access token",
          google_directory_id: directory.id,
          error: inspect(error)
        )

        raise Google.SyncError,
          reason: "Failed to get access token",
          cause: error,
          directory_id: directory.id,
          step: :get_access_token
    end
  end

  defp service_account_key(directory) do
    case directory.legacy_service_account_key do
      key when is_map(key) and map_size(key) > 0 ->
        key

      _ ->
        config = Portal.Config.fetch_env!(:portal, Google.APIClient)
        config[:service_account_key] |> JSON.decode!()
    end
  end

  defp fetch_and_sync_all(directory, access_token, synced_at) do
    # Sync users first
    sync_users(directory, access_token, synced_at)

    # Then sync groups and their members
    sync_groups(directory, access_token, synced_at)

    # Finally sync organization units
    sync_org_units(directory, access_token, synced_at)

    :ok
  end

  defp sync_users(directory, access_token, synced_at) do
    Logger.debug("Streaming users", google_directory_id: directory.id)

    Google.APIClient.stream_users(access_token, directory.domain)
    |> Stream.each(fn
      {:error, error} ->
        Logger.debug("Failed to stream users",
          google_directory_id: directory.id,
          error: inspect(error)
        )

        raise Google.SyncError,
          reason: "Failed to stream users",
          cause: error,
          directory_id: directory.id,
          step: :stream_users

      users when is_list(users) ->
        Logger.debug("Received users page",
          google_directory_id: directory.id,
          count: length(users)
        )

        # Build identities for these users - validate required fields
        identities =
          Enum.map(users, fn user ->
            # Ensure critical fields exist
            unless user["id"] do
              raise Google.SyncError,
                reason: "User missing required 'id' field",
                cause: user,
                directory_id: directory.id,
                step: :process_user
            end

            map_user_to_identity(user, directory.id)
          end)

        unless Enum.empty?(identities) do
          batch_upsert_identities(directory, synced_at, identities)
        end
    end)
    |> Stream.run()
  end

  defp sync_groups(directory, access_token, synced_at) do
    Logger.debug("Streaming groups", google_directory_id: directory.id)

    Google.APIClient.stream_groups(access_token, directory.domain)
    |> Stream.each(fn
      {:error, error} ->
        Logger.debug("Failed to stream groups",
          google_directory_id: directory.id,
          error: inspect(error)
        )

        raise Google.SyncError,
          reason: "Failed to stream groups",
          cause: error,
          directory_id: directory.id,
          step: :stream_groups

      groups when is_list(groups) ->
        Logger.debug("Received groups page",
          google_directory_id: directory.id,
          count: length(groups)
        )

        # Build and sync groups - validate required fields are present
        group_attrs =
          Enum.map(groups, fn group ->
            # Ensure critical fields exist - if Google returns incomplete data, we must fail
            unless group["id"] do
              raise Google.SyncError,
                reason: "Group missing required 'id' field",
                cause: group,
                directory_id: directory.id,
                step: :process_group
            end

            unless group["name"] || group["email"] do
              raise Google.SyncError,
                reason: "Group missing both 'name' and 'email' fields",
                cause: group,
                directory_id: directory.id,
                step: :process_group
            end

            %{
              idp_id: group["id"],
              name: group["name"] || group["email"]
            }
          end)

        unless Enum.empty?(group_attrs) do
          batch_upsert_groups(directory, synced_at, group_attrs)
        end

        # For each group, stream and sync members
        Enum.each(groups, fn group ->
          sync_group_members(directory, access_token, synced_at, group)
        end)
    end)
    |> Stream.run()
  end

  defp sync_group_members(directory, access_token, synced_at, group) do
    group_key = group["id"]
    group_name = group["name"] || group["email"]

    Logger.debug("Streaming members for group",
      google_directory_id: directory.id,
      group_key: group_key,
      group_name: group_name
    )

    Google.APIClient.stream_group_members(access_token, group_key)
    |> Stream.each(fn
      {:error, error} ->
        Logger.error("Failed to fetch members for group",
          group_key: group_key,
          group_name: group_name,
          error: inspect(error),
          google_directory_id: directory.id
        )

        raise Google.SyncError,
          reason: "Failed to stream group members for #{group_name}",
          cause: error,
          directory_id: directory.id,
          step: :stream_group_members

      members when is_list(members) ->
        process_group_members_page(directory, synced_at, group_key, group_name, members)
    end)
    |> Stream.run()
  end

  defp process_group_members_page(directory, synced_at, group_key, group_name, members) do
    Logger.debug("Received members page",
      google_directory_id: directory.id,
      group_key: group_key,
      count: length(members)
    )

    # Filter only user members (not groups or other types)
    user_members = Enum.filter(members, fn member -> member["type"] == "USER" end)

    # Build memberships (group_idp_id, user_idp_id) - validate required fields
    memberships =
      Enum.map(user_members, fn member ->
        unless member["id"] do
          raise Google.SyncError,
            reason: "Member missing required 'id' field in group #{group_name}",
            cause: member,
            directory_id: directory.id,
            step: :process_member
        end

        {group_key, member["id"]}
      end)

    unless Enum.empty?(memberships) do
      batch_upsert_memberships(directory, synced_at, memberships)
    end
  end

  defp sync_org_units(directory, access_token, synced_at) do
    Logger.debug("Streaming organization units", google_directory_id: directory.id)

    Google.APIClient.stream_organization_units(access_token)
    |> Stream.each(fn
      {:error, error} ->
        Logger.debug("Failed to stream organization units",
          google_directory_id: directory.id,
          error: inspect(error)
        )

        raise Google.SyncError,
          reason: "Failed to stream organization units",
          cause: error,
          directory_id: directory.id,
          step: :stream_org_units

      org_units when is_list(org_units) ->
        Logger.debug("Received organization units page",
          google_directory_id: directory.id,
          count: length(org_units)
        )

        # Build org unit attrs - validate required fields
        org_unit_attrs =
          Enum.map(org_units, fn org_unit ->
            unless org_unit["orgUnitId"] do
              raise Google.SyncError,
                reason: "Organization unit missing required 'orgUnitId' field",
                cause: org_unit,
                directory_id: directory.id,
                step: :process_org_unit
            end

            unless org_unit["name"] do
              raise Google.SyncError,
                reason: "Organization unit missing required 'name' field",
                cause: org_unit,
                directory_id: directory.id,
                step: :process_org_unit
            end

            unless org_unit["orgUnitPath"] do
              raise Google.SyncError,
                reason: "Organization unit missing required 'orgUnitPath' field",
                cause: org_unit,
                directory_id: directory.id,
                step: :process_org_unit
            end

            %{
              idp_id: org_unit["orgUnitId"],
              name: org_unit["name"]
            }
          end)

        unless Enum.empty?(org_unit_attrs) do
          batch_upsert_org_units(directory, synced_at, org_unit_attrs)
        end

        # For each org unit, stream and sync members
        Enum.each(org_units, fn org_unit ->
          sync_org_unit_members(directory, access_token, synced_at, org_unit)
        end)
    end)
    |> Stream.run()
  end

  defp sync_org_unit_members(directory, access_token, synced_at, org_unit) do
    org_unit_id = org_unit["orgUnitId"]
    org_unit_name = org_unit["name"]
    org_unit_path = org_unit["orgUnitPath"]

    Logger.debug("Streaming members for organization unit",
      google_directory_id: directory.id,
      org_unit_id: org_unit_id,
      org_unit_name: org_unit_name,
      org_unit_path: org_unit_path
    )

    Google.APIClient.stream_organization_unit_members(access_token, org_unit_path)
    |> Stream.each(fn
      {:error, error} ->
        Logger.error("Failed to fetch users for organization unit",
          org_unit_id: org_unit_id,
          org_unit_name: org_unit_name,
          org_unit_path: org_unit_path,
          error: inspect(error),
          google_directory_id: directory.id
        )

        raise Google.SyncError,
          reason: "Failed to stream org unit users for #{org_unit_name}",
          cause: error,
          directory_id: directory.id,
          step: :stream_org_unit_members

      users when is_list(users) ->
        process_org_unit_members_page(directory, synced_at, org_unit_id, org_unit_name, users)
    end)
    |> Stream.run()
  end

  defp process_org_unit_members_page(directory, synced_at, org_unit_id, org_unit_name, users) do
    Logger.debug("Received users page for organization unit",
      google_directory_id: directory.id,
      org_unit_id: org_unit_id,
      count: length(users)
    )

    # Build memberships (org_unit_idp_id, user_idp_id) - validate required fields
    memberships =
      Enum.map(users, fn user ->
        unless user["id"] do
          raise Google.SyncError,
            reason: "User missing required 'id' field in organization unit #{org_unit_name}",
            cause: user,
            directory_id: directory.id,
            step: :process_org_unit_member
        end

        {org_unit_id, user["id"]}
      end)

    unless Enum.empty?(memberships) do
      batch_upsert_memberships(directory, synced_at, memberships)
    end
  end

  defp batch_upsert_identities(directory, synced_at, identities) do
    account_id = directory.account_id
    directory_id = directory.id

    case Database.batch_upsert_identities(account_id, directory_id, synced_at, identities) do
      {:ok, %{upserted_identities: count}} ->
        Logger.debug("Upserted #{count} identities", google_directory_id: directory.id)
        :ok

      {:error, reason} ->
        Logger.error("Failed to upsert identities",
          reason: inspect(reason),
          count: length(identities),
          google_directory_id: directory.id
        )

        :error
    end
  end

  defp batch_upsert_groups(directory, synced_at, groups) do
    account_id = directory.account_id
    directory_id = directory.id

    {:ok, %{upserted_groups: count}} =
      Database.batch_upsert_groups(account_id, directory_id, synced_at, groups, :group)

    Logger.debug("Upserted #{count} groups", google_directory_id: directory.id)
    :ok
  end

  defp batch_upsert_memberships(directory, synced_at, memberships) do
    account_id = directory.account_id
    directory_id = directory.id

    case Database.batch_upsert_memberships(account_id, directory_id, synced_at, memberships) do
      {:ok, %{upserted_memberships: count}} ->
        Logger.debug("Upserted #{count} memberships", google_directory_id: directory.id)
        :ok

      {:error, reason} ->
        Logger.error("Failed to upsert memberships",
          reason: inspect(reason),
          count: length(memberships),
          google_directory_id: directory.id
        )

        :error
    end
  end

  defp batch_upsert_org_units(directory, synced_at, org_units) do
    account_id = directory.account_id
    directory_id = directory.id

    {:ok, %{upserted_groups: count}} =
      Database.batch_upsert_groups(account_id, directory_id, synced_at, org_units, :org_unit)

    Logger.debug("Upserted #{count} organization units", google_directory_id: directory.id)
    :ok
  end

  defp delete_unsynced(directory, synced_at) do
    account_id = directory.account_id
    directory_id = directory.id

    # Delete groups that weren't synced
    {deleted_groups_count, _} =
      Database.delete_unsynced_groups(account_id, directory_id, synced_at)

    Logger.debug("Deleted unsynced groups",
      google_directory_id: directory.id,
      count: deleted_groups_count
    )

    # Delete identities that weren't synced
    {deleted_identities_count, _} =
      Database.delete_unsynced_identities(account_id, directory_id, synced_at)

    Logger.debug("Deleted unsynced identities",
      google_directory_id: directory.id,
      count: deleted_identities_count
    )

    # Delete memberships that weren't synced
    {deleted_memberships_count, _} =
      Database.delete_unsynced_memberships(account_id, directory_id, synced_at)

    Logger.debug("Deleted unsynced group memberships",
      google_directory_id: directory.id,
      count: deleted_memberships_count
    )

    # Delete actors that no longer have any identities and were created by this directory
    {deleted_actors_count, _} =
      Database.delete_actors_without_identities(account_id, directory_id)

    Logger.debug("Deleted actors without identities",
      google_directory_id: directory.id,
      count: deleted_actors_count
    )
  end

  defp map_user_to_identity(user, directory_id) do
    # Map Google Workspace user fields to our identity schema
    # Validate that critical fields are present
    primary_email = user["primaryEmail"]

    unless primary_email do
      raise Google.SyncError,
        reason: "User missing required 'primaryEmail' field",
        cause: user,
        directory_id: directory_id,
        step: :process_user
    end

    %{
      idp_id: user["id"],
      email: primary_email,
      name: Map.get(user, "name", %{}) |> Map.get("fullName"),
      given_name: Map.get(user, "name", %{}) |> Map.get("givenName"),
      family_name: Map.get(user, "name", %{}) |> Map.get("familyName"),
      preferred_username: primary_email,
      picture: Map.get(user, "thumbnailPhotoUrl")
    }
  end

  defmodule Database do
    import Ecto.Query
    alias Portal.Repo

    @issuer "https://accounts.google.com"

    def get_directory(id) do
      from(d in Google.Directory,
        join: a in Portal.Account,
        on: a.id == d.account_id,
        where: d.id == ^id,
        where: d.is_disabled == false,
        where: is_nil(a.disabled_at)
      )
      # credo:disable-for-next-line Credo.Check.Warning.RepoMissingSubject
      |> Repo.one()
    end

    def update_directory(changeset) do
      # credo:disable-for-next-line Credo.Check.Warning.RepoMissingSubject
      changeset |> Repo.update()
    end

    def batch_upsert_identities(_account_id, _directory_id, _last_synced_at, []),
      do: {:ok, %{upserted_identities: 0}}

    def batch_upsert_identities(account_id, directory_id, last_synced_at, identity_attrs) do
      query = build_identity_upsert_query(length(identity_attrs))

      params =
        build_identity_upsert_params(
          account_id,
          directory_id,
          last_synced_at,
          identity_attrs
        )

      case Repo.query(query, params) do
        {:ok, %Postgrex.Result{rows: rows}} -> {:ok, %{upserted_identities: length(rows)}}
        {:error, reason} -> {:error, reason}
      end
    end

    defp build_identity_upsert_query(count) do
      # Each identity has 7 fields: idp_id, email, name, given_name, family_name, preferred_username, picture
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
        AS t(idp_id, email, name, given_name, family_name, preferred_username, picture)
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
        SELECT atc.new_actor_id AS actor_id, atc.idp_id, id.email, id.name, id.given_name, id.family_name, id.preferred_username, id.picture
        FROM actors_to_create atc
        JOIN input_data id ON id.idp_id = atc.idp_id
        UNION ALL
        SELECT ei.actor_id, ei.idp_id, id.email, id.name, id.given_name, id.family_name, id.preferred_username, id.picture
        FROM existing_identities ei
        JOIN input_data id ON id.idp_id = ei.idp_id
        UNION ALL
        SELECT eabe.actor_id, eabe.idp_id, id.email, id.name, id.given_name, id.family_name, id.preferred_username, id.picture
        FROM existing_actors_by_email eabe
        JOIN input_data id ON id.idp_id = eabe.idp_id
      )
      INSERT INTO external_identities (
        id, actor_id, issuer, idp_id, directory_id, email, name, given_name, family_name, preferred_username, picture,
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
        aam.picture,
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
        picture = EXCLUDED.picture,
        last_synced_at = EXCLUDED.last_synced_at,
        updated_at = EXCLUDED.updated_at
      WHERE external_identities.last_synced_at IS NULL
        OR external_identities.last_synced_at < EXCLUDED.last_synced_at
      RETURNING 1
      """
    end

    defp build_identity_upsert_params(account_id, directory_id, last_synced_at, attrs) do
      params =
        Enum.flat_map(attrs, fn a ->
          [
            a.idp_id,
            a.email,
            a.name,
            Map.get(a, :given_name),
            Map.get(a, :family_name),
            Map.get(a, :preferred_username),
            Map.get(a, :picture)
          ]
        end)

      params ++
        [
          Ecto.UUID.dump!(account_id),
          @issuer,
          Ecto.UUID.dump!(directory_id),
          last_synced_at
        ]
    end

    def batch_upsert_groups(_account_id, _directory_id, _last_synced_at, [], _entity_type),
      do: {:ok, %{upserted_groups: 0}}

    def batch_upsert_groups(account_id, directory_id, last_synced_at, group_attrs, entity_type) do
      # Convert to raw SQL to support conditional updates based on last_synced_at
      query = build_group_upsert_query(length(group_attrs))

      params =
        build_group_upsert_params(
          account_id,
          directory_id,
          last_synced_at,
          group_attrs,
          entity_type
        )

      case Repo.query(query, params) do
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
      entity_type = offset + 4

      """
      WITH input_data (idp_id, name) AS (
        VALUES #{values_clause}
      )
      INSERT INTO groups (
        id, name, directory_id, idp_id, account_id,
        inserted_at, updated_at, type, entity_type, last_synced_at
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
        $#{entity_type},
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

    defp build_group_upsert_params(
           account_id,
           directory_id,
           last_synced_at,
           group_attrs,
           entity_type
         ) do
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
          last_synced_at,
          to_string(entity_type)
        ]
    end

    def batch_upsert_memberships(_account_id, _directory_id, _last_synced_at, []),
      do: {:ok, %{upserted_memberships: 0}}

    def batch_upsert_memberships(account_id, directory_id, last_synced_at, tuples) do
      query = build_membership_upsert_query(length(tuples))

      params =
        build_membership_upsert_params(account_id, directory_id, last_synced_at, tuples)

      case Repo.query(query, params) do
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

    defp build_membership_upsert_params(account_id, _directory_id, last_synced_at, tuples) do
      params =
        Enum.flat_map(tuples, fn {group_idp_id, user_idp_id} ->
          [group_idp_id, user_idp_id]
        end)

      params ++ [Ecto.UUID.dump!(account_id), @issuer, last_synced_at]
    end

    def delete_unsynced_groups(account_id, directory_id, synced_at) do
      query =
        from(g in Portal.Group,
          where: g.account_id == ^account_id,
          where: g.directory_id == ^directory_id,
          where: g.last_synced_at < ^synced_at or is_nil(g.last_synced_at)
        )

      # credo:disable-for-next-line Credo.Check.Warning.RepoMissingSubject
      query |> Repo.delete_all()
    end

    def delete_unsynced_identities(account_id, directory_id, synced_at) do
      query =
        from(i in Portal.ExternalIdentity,
          where: i.account_id == ^account_id,
          where: i.directory_id == ^directory_id,
          where: i.last_synced_at < ^synced_at or is_nil(i.last_synced_at)
        )

      # credo:disable-for-next-line Credo.Check.Warning.RepoMissingSubject
      query |> Repo.delete_all()
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

      # credo:disable-for-next-line Credo.Check.Warning.RepoMissingSubject
      query |> Repo.delete_all()
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

      # credo:disable-for-next-line Credo.Check.Warning.RepoMissingSubject
      query |> Repo.delete_all()
    end
  end
end
