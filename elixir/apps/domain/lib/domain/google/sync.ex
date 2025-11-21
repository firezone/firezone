defmodule Domain.Google.Sync do
  @moduledoc """
  Oban worker for syncing users, groups, and memberships from Google Workspace.
  """
  # Retries and uniqueness are handled by the scheduler
  use Oban.Worker,
    queue: :google_sync,
    max_attempts: 1

  alias Domain.{Safe, Google}
  alias __MODULE__.Query
  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"directory_id" => directory_id}}) do
    Logger.info("Starting Google directory sync",
      google_directory_id: directory_id,
      timestamp: DateTime.utc_now()
    )

    case Query.get_directory(directory_id) |> Safe.unscoped() |> Safe.one() do
      nil ->
        Logger.info("Google directory deleted or sync disabled, skipping",
          google_directory_id: directory_id
        )

      directory ->
        # Perform the sync
        sync(directory)
    end

    :ok
  end

  defp update(directory, attrs) do
    changeset = Ecto.Changeset.cast(directory, attrs, [:synced_at])
    {:ok, _directory} = changeset |> Safe.unscoped() |> Safe.update()
  end

  defp sync(%Google.Directory{} = directory) do
    access_token = get_access_token!(directory)
    synced_at = DateTime.utc_now()

    fetch_and_sync_all(directory, access_token, synced_at)
    delete_unsynced(directory, synced_at)
    update(directory, %{"synced_at" => synced_at})

    duration = DateTime.diff(DateTime.utc_now(), synced_at)

    Logger.info("Finished Google directory sync in #{duration} seconds",
      google_directory_id: directory.id
    )
  end

  defp get_access_token!(directory) do
    Logger.debug("Getting access token", google_directory_id: directory.id)

    case Google.APIClient.get_access_token(directory.impersonation_email) do
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

  defp fetch_and_sync_all(directory, access_token, synced_at) do
    # Sync users first
    sync_users(directory, access_token, synced_at)

    # Then sync groups and their members
    sync_groups(directory, access_token, synced_at)

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

        # Build identities for these users
        identities = Enum.map(users, &map_user_to_identity/1)

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

        # Build and sync groups
        group_attrs =
          Enum.map(groups, fn group ->
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
          group_key = group["id"]
          group_name = group["name"] || group["email"]

          Logger.debug("Streaming members for group",
            google_directory_id: directory.id,
            group_key: group_key,
            group_name: group_name
          )

          Google.APIClient.stream_group_members(access_token, group_key)
          |> Stream.each(fn
            {:error, reason} ->
              Logger.debug("Failed to fetch members for group",
                group_key: group_key,
                reason: inspect(reason),
                google_directory_id: directory.id
              )

            members when is_list(members) ->
              Logger.debug("Received members page",
                google_directory_id: directory.id,
                group_key: group_key,
                count: length(members)
              )

              # Filter only user members (not groups or other types)
              user_members =
                Enum.filter(members, fn member ->
                  member["type"] == "USER"
                end)

              # Build memberships (group_idp_id, user_idp_id)
              memberships =
                Enum.map(user_members, fn member ->
                  {group_key, member["id"]}
                end)

              unless Enum.empty?(memberships) do
                batch_upsert_memberships(directory, synced_at, memberships)
              end
          end)
          |> Stream.run()
        end)
    end)
    |> Stream.run()
  end

  defp batch_upsert_identities(directory, synced_at, identities) do
    account_id = directory.account_id
    directory_id = directory.id
    domain = directory.domain

    case Query.batch_upsert_identities(account_id, directory_id, domain, synced_at, identities) do
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
    domain = directory.domain

    {:ok, %{upserted_groups: count}} =
      Query.batch_upsert_groups(account_id, synced_at, domain, groups)

    Logger.debug("Upserted #{count} groups", google_directory_id: directory.id)
    :ok
  end

  defp batch_upsert_memberships(directory, synced_at, memberships) do
    account_id = directory.account_id
    domain = directory.domain

    case Query.batch_upsert_memberships(account_id, synced_at, domain, memberships) do
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

  defp delete_unsynced(directory, synced_at) do
    account_id = directory.account_id
    domain = directory.domain

    # Delete groups that weren't synced
    {deleted_groups_count, _} = Query.delete_unsynced_groups(account_id, domain, synced_at)

    Logger.debug("Deleted unsynced groups",
      google_directory_id: directory.id,
      count: deleted_groups_count
    )

    # Delete identities that weren't synced
    {deleted_identities_count, _} =
      Query.delete_unsynced_identities(account_id, domain, synced_at)

    Logger.debug("Deleted unsynced identities",
      google_directory_id: directory.id,
      count: deleted_identities_count
    )

    # Delete memberships that weren't synced
    {deleted_memberships_count, _} =
      Query.delete_unsynced_memberships(account_id, domain, synced_at)

    Logger.debug("Deleted unsynced group memberships",
      google_directory_id: directory.id,
      count: deleted_memberships_count
    )

    # Delete actors that no longer have any identities and were created by this directory
    {deleted_actors_count, _} = Query.delete_actors_without_identities(account_id, directory.id)

    Logger.debug("Deleted actors without identities",
      google_directory_id: directory.id,
      count: deleted_actors_count
    )
  end

  defp map_user_to_identity(user) do
    # Map Google Workspace user fields to our identity schema
    primary_email = user["primaryEmail"]

    %{
      idp_id: user["id"],
      email: primary_email,
      name: Map.get(user, "name", %{}) |> Map.get("fullName"),
      given_name: Map.get(user, "name", %{}) |> Map.get("givenName"),
      family_name: Map.get(user, "name", %{}) |> Map.get("familyName"),
      preferred_username: primary_email
    }
  end

  defmodule Query do
    import Ecto.Query
    alias Domain.Safe

    @issuer "https://accounts.google.com"

    def get_directory(id) do
      from(d in Google.Directory, as: :directories)
      |> where([directories: d], d.id == ^id)
      |> where([directories: d], d.is_disabled == false)
    end

    def batch_upsert_identities(_account_id, _directory_id, _domain, _last_synced_at, []),
      do: {:ok, %{upserted_identities: 0}}

    def batch_upsert_identities(account_id, directory_id, domain, last_synced_at, identity_attrs) do
      query = build_identity_upsert_query(length(identity_attrs))

      params =
        build_identity_upsert_params(
          account_id,
          directory_id,
          domain,
          last_synced_at,
          identity_attrs
        )

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
      directory_id = offset + 3
      directory = offset + 4
      last_synced_at = offset + 5

      """
      WITH input_data AS (
        SELECT * FROM (VALUES #{values_clause})
        AS t(idp_id, email, name, given_name, family_name, preferred_username)
      ),
      existing_identities AS (
        SELECT ai.id, ai.actor_id, ai.idp_id
        FROM auth_identities ai
        WHERE ai.account_id = $#{account_id}
          AND ai.directory = $#{directory}
          AND ai.idp_id IN (SELECT idp_id FROM input_data)
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
        INSERT INTO actors (id, type, account_id, name, email, created_by, created_by_directory_id, inserted_at, updated_at)
        SELECT
          new_actor_id,
          'account_user',
          $#{account_id},
          name,
          email,
          'system',
          $#{directory_id},
          $#{last_synced_at},
          $#{last_synced_at}
        FROM actors_to_create
        RETURNING id, name
      ),
      all_actor_mappings AS (
        SELECT atc.new_actor_id AS actor_id, atc.idp_id, id.email, id.name, id.given_name, id.family_name, id.preferred_username
        FROM actors_to_create atc
        JOIN input_data id ON id.idp_id = atc.idp_id
        UNION ALL
        SELECT ei.actor_id, ei.idp_id, id.email, id.name, id.given_name, id.family_name, id.preferred_username
        FROM existing_identities ei
        JOIN input_data id ON id.idp_id = ei.idp_id
        UNION ALL
        SELECT eabe.actor_id, eabe.idp_id, id.email, id.name, id.given_name, id.family_name, id.preferred_username
        FROM existing_actors_by_email eabe
        JOIN input_data id ON id.idp_id = eabe.idp_id
      )
      INSERT INTO auth_identities (
        id, actor_id, issuer, idp_id, directory, name, given_name, family_name, preferred_username,
        last_synced_at, account_id, created_by, inserted_at
      )
      SELECT
        COALESCE(ei.id, uuid_generate_v4()),
        aam.actor_id,
        $#{issuer},
        aam.idp_id,
        $#{directory},
        aam.name,
        aam.given_name,
        aam.family_name,
        aam.preferred_username,
        $#{last_synced_at},
        $#{account_id},
        'system',
        $#{last_synced_at}
      FROM all_actor_mappings aam
      LEFT JOIN existing_identities ei ON ei.idp_id = aam.idp_id
      ON CONFLICT (account_id, issuer, idp_id) WHERE (issuer IS NOT NULL OR idp_id IS NOT NULL)
      DO UPDATE SET
        directory = EXCLUDED.directory,
        name = EXCLUDED.name,
        given_name = EXCLUDED.given_name,
        family_name = EXCLUDED.family_name,
        preferred_username = EXCLUDED.preferred_username,
        last_synced_at = EXCLUDED.last_synced_at
      RETURNING 1
      """
    end

    defp build_identity_upsert_params(account_id, directory_id, domain, last_synced_at, attrs) do
      directory = "google:#{domain}"

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

      params ++
        [
          Ecto.UUID.dump!(account_id),
          @issuer,
          Ecto.UUID.dump!(directory_id),
          directory,
          last_synced_at
        ]
    end

    def batch_upsert_groups(_account_id, _last_synced_at, _domain, []),
      do: {:ok, %{upserted_groups: 0}}

    def batch_upsert_groups(account_id, last_synced_at, domain, group_attrs) do
      directory = "google:#{domain}"

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
            last_synced_at: last_synced_at
          }
        end)

      {count, _} =
        Safe.unscoped()
        |> Safe.insert_all(Domain.Actors.Group, values,
          on_conflict: {:replace, [:name, :last_synced_at, :updated_at]},
          conflict_target:
            {:unsafe_fragment, ~s/(account_id, directory, idp_id) WHERE directory <> 'firezone'/},
          returning: false
        )

      {:ok, %{upserted_groups: count}}
    end

    def batch_upsert_memberships(_account_id, _last_synced_at, _domain, []),
      do: {:ok, %{upserted_memberships: 0}}

    def batch_upsert_memberships(account_id, last_synced_at, domain, tuples) do
      query = build_membership_upsert_query(length(tuples))

      params =
        build_membership_upsert_params(account_id, last_synced_at, domain, tuples)

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
      last_synced_at = offset + 2
      directory = offset + 3

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
          AND ai.directory = $#{directory}
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

    defp build_membership_upsert_params(account_id, last_synced_at, domain, tuples) do
      directory = "google:#{domain}"

      params =
        Enum.flat_map(tuples, fn {group_idp_id, user_idp_id} ->
          [group_idp_id, user_idp_id]
        end)

      params ++ [Ecto.UUID.dump!(account_id), last_synced_at, directory]
    end

    def delete_unsynced_groups(account_id, domain, synced_at) do
      directory = "google:#{domain}"

      query =
        from(g in Domain.Actors.Group,
          where: g.account_id == ^account_id,
          where: g.directory == ^directory,
          where: g.last_synced_at != ^synced_at or is_nil(g.last_synced_at)
        )

      Safe.delete_all(Safe.unscoped(), query)
    end

    def delete_unsynced_identities(account_id, domain, synced_at) do
      directory = "google:#{domain}"

      query =
        from(i in Domain.Auth.Identity,
          where: i.account_id == ^account_id,
          where: i.directory == ^directory,
          where: i.last_synced_at != ^synced_at or is_nil(i.last_synced_at)
        )

      Safe.delete_all(Safe.unscoped(), query)
    end

    def delete_unsynced_memberships(account_id, domain, synced_at) do
      directory = "google:#{domain}"

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

    def delete_actors_without_identities(account_id, directory_id) do
      # Delete actors that no longer have any identities
      # This cleans up actors whose identities were deleted in the previous step
      # Only delete actors created by this specific directory
      query =
        from(a in Domain.Actors.Actor,
          where: a.account_id == ^account_id,
          where: a.created_by_directory_id == ^directory_id,
          where:
            fragment(
              "NOT EXISTS (SELECT 1 FROM auth_identities WHERE actor_id = ?)",
              a.id
            )
        )

      Safe.delete_all(Safe.unscoped(), query)
    end
  end
end
