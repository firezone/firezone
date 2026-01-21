defmodule Portal.Okta.Sync do
  @moduledoc """
  Worker to sync identities from Okta for a given directory.
  """
  use Oban.Worker,
    queue: :okta_sync,
    max_attempts: 1,
    unique: [
      period: :infinity,
      states: [:available, :scheduled, :executing],
      keys: [:directory_id]
    ]

  alias Portal.Okta
  alias __MODULE__.Database

  require Logger
  require OpenTelemetry.Tracer

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"directory_id" => directory_id}}) do
    Logger.info("Starting Okta directory sync",
      okta_directory_id: directory_id,
      timestamp: DateTime.utc_now()
    )

    case Database.get_directory(directory_id) do
      nil ->
        Logger.info("Okta directory not found, disabled, or account disabled, skipping",
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
    synced_at = DateTime.utc_now()

    apps = get_apps!(client, access_token, directory)
    sync_all_apps!(apps, client, access_token, directory, synced_at)
    sync_all_memberships!(client, access_token, directory, synced_at)
    check_deletion_threshold!(directory, synced_at)
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
          reason: "Failed to get access token",
          cause: error,
          directory_id: directory.id,
          step: :get_access_token
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
          reason: "Failed to fetch apps",
          cause: error,
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
      Enum.reduce(batch, {[], []}, fn
        {:ok, user_data}, {users, errors} ->
          user = get_in(user_data, ["_embedded", "user"])
          {[user | users], errors}

        {:error, reason}, {users, errors} ->
          {users, [reason | errors]}
      end)

    # If there are any errors in the batch, raise the first one
    case errors do
      [error | _] ->
        raise Okta.SyncError,
          reason: "Failed to stream app users",
          cause: error,
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
              reason: "Failed to upsert identities",
              cause: reason,
              directory_id: directory.id,
              step: :batch_upsert_identities
        end
    end
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
          group = get_in(group_data, ["_embedded", "group"])
          {[group | groups], errors}

        {:error, reason}, {groups, errors} ->
          {groups, [reason | errors]}
      end)

    # If there are any errors in the batch, raise the first one
    case errors do
      [error | _] ->
        raise Okta.SyncError,
          reason: "Failed to stream app groups",
          cause: error,
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
          reason: "Failed to upsert memberships",
          cause: reason,
          directory_id: directory_id,
          step: :batch_upsert_memberships
    end
  end

  defp fetch_group_members!(group_idp_id, client, token, directory_id) do
    Okta.APIClient.stream_group_members(group_idp_id, client, token)
    |> Enum.reduce([], fn
      {:ok, member}, acc ->
        if member["status"] == "ACTIVE" do
          [member["id"] | acc]
        else
          acc
        end

      {:error, reason}, _acc ->
        raise Okta.SyncError,
          reason: "Failed to stream group members",
          cause: reason,
          directory_id: directory_id,
          step: :stream_group_members
    end)
    |> Enum.reverse()
  end

  # Helper to build issuer URL
  defp issuer(directory), do: "https://#{directory.okta_domain}"

  # Parses an Okta user API response into a structured map
  defp parse_okta_user(user, directory_id) do
    profile = user["profile"] || %{}

    email = profile["email"]

    unless email do
      raise Okta.SyncError,
        reason: "User missing required 'email' field",
        cause: user,
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
  @deletion_threshold 0.90
  @min_records_for_threshold 10

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

  defp check_resource_threshold!(counts, resource_name, directory) do
    %{total: total, to_delete: to_delete} = counts

    # Only apply threshold check if we have enough records
    if total >= @min_records_for_threshold do
      deletion_percentage = to_delete / total

      if deletion_percentage >= @deletion_threshold do
        Logger.error(
          "Deletion threshold exceeded for #{resource_name}",
          okta_directory_id: directory.id,
          total: total,
          to_delete: to_delete,
          percentage: Float.round(deletion_percentage * 100, 1)
        )

        raise Okta.SyncError,
          reason:
            "Sync would delete #{to_delete} of #{total} #{resource_name} " <>
              "(#{Float.round(deletion_percentage * 100, 0)}%). " <>
              "This may indicate the Okta application was misconfigured or removed. " <>
              "Please verify your Okta configuration and re-verify the directory connection.",
          cause: %{
            resource: resource_name,
            total: total,
            to_delete: to_delete,
            threshold: @deletion_threshold
          },
          directory_id: directory.id,
          step: :check_deletion_threshold
      else
        Logger.debug(
          "Deletion threshold check passed for #{resource_name}",
          okta_directory_id: directory.id,
          total: total,
          to_delete: to_delete,
          percentage: Float.round(deletion_percentage * 100, 1)
        )
      end
    else
      Logger.debug(
        "Skipping deletion threshold check for #{resource_name} - too few records",
        okta_directory_id: directory.id,
        total: total,
        min_required: @min_records_for_threshold
      )
    end
  end

  defmodule Database do
    import Ecto.Query
    alias Portal.Safe

    def get_directory(id) do
      from(d in Okta.Directory,
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

    # Count functions for circuit breaker threshold checks
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
          where: i.account_id == ^account_id,
          where: i.directory_id == ^directory_id,
          where: i.last_synced_at < ^synced_at or is_nil(i.last_synced_at),
          select: count(i.id)
        )
        |> Safe.unscoped()
        |> Safe.one!()

      %{total: total, to_delete: to_delete}
    end

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
          where: g.account_id == ^account_id,
          where: g.directory_id == ^directory_id,
          where: g.last_synced_at < ^synced_at or is_nil(g.last_synced_at),
          select: count(g.id)
        )
        |> Safe.unscoped()
        |> Safe.one!()

      %{total: total, to_delete: to_delete}
    end

    def get_synced_group_idp_ids(account_id, directory_id, synced_at) do
      from(g in Portal.Group,
        where: g.account_id == ^account_id,
        where: g.directory_id == ^directory_id,
        where: g.last_synced_at == ^synced_at,
        where: not is_nil(g.idp_id),
        select: g.idp_id
      )
      |> Safe.unscoped()
      |> Safe.all()
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
      last_synced_at = offset + 4

      """
      WITH input_data AS (
        SELECT * FROM (VALUES #{values_clause})
        AS t(idp_id, email, name, given_name, family_name, preferred_username)
      ),
      existing_identities AS (
        SELECT ei.id, ei.actor_id, ei.idp_id
        FROM external_identities ei
        WHERE ei.account_id = $#{account_id}
          AND ei.directory_id = $#{directory_id}
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
      INSERT INTO external_identities (
        id, actor_id, issuer, idp_id, directory_id, email, name, given_name, family_name, preferred_username,
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
            Map.get(a, :preferred_username)
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

    # Cleanup functions
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
end
