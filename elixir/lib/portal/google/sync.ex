defmodule Portal.Google.Sync do
  @moduledoc """
  Oban worker for syncing users, groups, and memberships from Google Workspace.

  Sync runs in four phases:
  1. Upsert seed groups (based on group_sync_mode), collect group idp_ids.
  2. Upsert org units (if orgunit_sync_enabled), collect {idp_id, path} pairs.
  3. Org unit member sync: per org unit, fetch users, upsert identities directly
     from the users payload (deduped via seen_user_ids), and upsert memberships.
  4. BFS group member sync: for each group, fetch direct members, upsert identities,
     discover GROUP-type members as sub-groups (fetching each via get_group for its
     display name), upsert them, and recurse. We collect direct user memberships and
     the group graph during traversal, then compute flattened memberships in-memory
     and upsert them in batches. A `seen_user_ids` set is threaded through to skip
     redundant batch_get_users calls for users already fetched in an earlier group.
  Finally, delete everything with a stale last_synced_at.
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
  @db_batch_size 500

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

    # Reconnect orphaned policies after sync (groups may have been recreated)
    reconnected = Portal.Policy.reconnect_orphaned_policies(directory.account_id)

    if reconnected > 0 do
      Logger.info("Reconnected #{reconnected} orphaned policies after sync",
        account_id: directory.account_id,
        google_directory_id: directory.id
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
          error: response,
          directory_id: directory.id,
          step: :get_access_token

      {:error, error} ->
        Logger.debug("Failed to get access token",
          google_directory_id: directory.id,
          error: inspect(error)
        )

        raise Google.SyncError,
          error: error,
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

        case config[:service_account_key] do
          key when is_binary(key) ->
            JSON.decode!(key)

          _ ->
            raise Google.SyncError,
              error: "service account key is not configured",
              directory_id: directory.id,
              step: :service_account_key
        end
    end
  end

  # Phase orchestration

  defp fetch_and_sync_all(directory, access_token, synced_at) do
    # Phase 1: Upsert seed groups (based on group_sync_mode), collect idp_ids
    group_idp_ids = sync_groups_phase(directory, access_token, synced_at)

    # Phase 2: Upsert org units (if enabled), collect {idp_id, path} pairs
    org_unit_entries = sync_org_units_phase(directory, access_token, synced_at)

    # Phase 3: Org unit member sync.
    # Per org unit: fetch users → upsert identities directly from user payload (deduped)
    # → upsert memberships. Returns the set of user IDs already synced.
    seen_user_ids =
      sync_org_unit_members_phase(
        directory,
        access_token,
        synced_at,
        org_unit_entries,
        MapSet.new()
      )

    # Phase 4: BFS group member sync.
    # For each group: fetch direct members → batch_get_users only for unseen users
    # → upsert identities → discover GROUP-type sub-groups → recurse.
    sync_group_members_bfs(
      directory,
      access_token,
      synced_at,
      group_idp_ids,
      seen_user_ids
    )

    :ok
  end

  # Phase 1: groups

  @firezone_sync_prefix "firezone-sync"

  defp sync_groups_phase(directory, access_token, synced_at) do
    case directory.group_sync_mode do
      :disabled ->
        []

      :all ->
        upsert_groups(directory, access_token, synced_at)

      :filtered ->
        # Google's query language does not support OR, so we issue two queries and
        # rely on idempotent upserts to deduplicate groups that match both.
        ids1 =
          upsert_groups(directory, access_token, synced_at,
            query: "email:#{@firezone_sync_prefix}*"
          )

        ids2 =
          upsert_groups(directory, access_token, synced_at,
            query: "name:[#{@firezone_sync_prefix}]*"
          )

        Enum.uniq(ids1 ++ ids2)
    end
  end

  defp upsert_groups(directory, access_token, synced_at, opts \\ []) do
    Logger.debug("Streaming groups", google_directory_id: directory.id)

    Google.APIClient.stream_groups(access_token, directory.domain, opts)
    |> Enum.reduce([], fn
      {:error, error}, _acc ->
        Logger.debug("Failed to stream groups",
          google_directory_id: directory.id,
          error: inspect(error)
        )

        raise Google.SyncError,
          error: error,
          directory_id: directory.id,
          step: :stream_groups

      groups, acc when is_list(groups) ->
        Logger.debug("Received groups page",
          google_directory_id: directory.id,
          count: length(groups)
        )

        group_attrs =
          Enum.map(groups, fn group ->
            validate_group!(group, directory)

            %{
              idp_id: group["id"],
              name: group["name"] || group["email"],
              email: group["email"]
            }
          end)

        unless Enum.empty?(group_attrs) do
          batch_upsert_groups(directory, synced_at, group_attrs)
        end

        group_ids = Enum.map(groups, & &1["id"])
        Enum.reverse(group_ids, acc)
    end)
    |> Enum.reverse()
  end

  # Phase 2: org units

  defp sync_org_units_phase(directory, access_token, synced_at) do
    if directory.orgunit_sync_enabled do
      upsert_org_units(directory, access_token, synced_at)
    else
      []
    end
  end

  defp upsert_org_units(directory, access_token, synced_at) do
    Logger.debug("Streaming organization units", google_directory_id: directory.id)

    Google.APIClient.stream_organization_units(access_token)
    |> Enum.reduce([], fn
      {:error, error}, _acc ->
        Logger.debug("Failed to stream organization units",
          google_directory_id: directory.id,
          error: inspect(error)
        )

        raise Google.SyncError,
          error: error,
          directory_id: directory.id,
          step: :stream_org_units

      org_units, acc when is_list(org_units) ->
        Logger.debug("Received organization units page",
          google_directory_id: directory.id,
          count: length(org_units)
        )

        org_unit_attrs =
          Enum.map(org_units, fn org_unit ->
            validate_org_unit!(org_unit, directory)

            %{
              idp_id: org_unit["orgUnitId"],
              name: org_unit["name"],
              email: nil
            }
          end)

        unless Enum.empty?(org_unit_attrs) do
          batch_upsert_org_units(directory, synced_at, org_unit_attrs)
        end

        entries = Enum.map(org_units, fn ou -> {ou["orgUnitId"], ou["orgUnitPath"]} end)
        Enum.reverse(entries, acc)
    end)
    |> Enum.reverse()
  end

  # Phase 3: BFS group member sync

  defp sync_group_members_bfs(
         directory,
         access_token,
         synced_at,
         seed_group_idp_ids,
         seen_user_ids
       ) do
    visited = MapSet.new(seed_group_idp_ids)
    queue = :queue.from_list(seed_group_idp_ids)

    initial_state = %{
      seen_user_ids: seen_user_ids,
      direct_users_by_group: %{},
      children_by_group: %{}
    }

    final_state = do_bfs(directory, access_token, synced_at, queue, visited, initial_state)

    upsert_flattened_group_memberships(
      directory,
      synced_at,
      final_state.children_by_group,
      final_state.direct_users_by_group
    )

    final_state.seen_user_ids
  end

  defp do_bfs(directory, access_token, synced_at, queue, visited, state) do
    case :queue.out(queue) do
      {:empty, _} ->
        state

      {{:value, group_idp_id}, remaining_queue} ->
        {next_queue, next_visited, next_state} =
          process_group_bfs_node(
            directory,
            access_token,
            synced_at,
            group_idp_id,
            remaining_queue,
            visited,
            state
          )

        do_bfs(directory, access_token, synced_at, next_queue, next_visited, next_state)
    end
  end

  defp process_group_bfs_node(
         directory,
         access_token,
         synced_at,
         group_idp_id,
         remaining_queue,
         visited,
         state
       ) do
    {user_tuples, sub_group_ids} = fetch_group_members(directory, access_token, group_idp_id)
    direct_user_ids = user_ids_set_from_memberships(user_tuples)

    next_seen_user_ids =
      sync_new_user_identities(
        directory,
        access_token,
        synced_at,
        direct_user_ids,
        state.seen_user_ids
      )

    next_state =
      state
      |> put_group_direct_users(group_idp_id, direct_user_ids)
      |> put_group_children(group_idp_id, sub_group_ids)
      |> Map.put(:seen_user_ids, next_seen_user_ids)

    {next_queue, next_visited} =
      enqueue_discovered_sub_groups(
        directory,
        access_token,
        synced_at,
        sub_group_ids,
        remaining_queue,
        visited
      )

    {next_queue, next_visited, next_state}
  end

  defp put_group_direct_users(state, group_idp_id, direct_user_ids) do
    %{
      state
      | direct_users_by_group: Map.put(state.direct_users_by_group, group_idp_id, direct_user_ids)
    }
  end

  defp put_group_children(state, group_idp_id, sub_group_ids) do
    children_set = MapSet.new(sub_group_ids)
    %{state | children_by_group: Map.put(state.children_by_group, group_idp_id, children_set)}
  end

  defp user_ids_set_from_memberships(memberships) do
    memberships
    |> Enum.map(fn {_, user_id} -> user_id end)
    |> MapSet.new()
  end

  defp upsert_flattened_group_memberships(
         _directory,
         _synced_at,
         children_by_group,
         direct_users_by_group
       )
       when map_size(children_by_group) == 0 and map_size(direct_users_by_group) == 0,
       do: :ok

  defp upsert_flattened_group_memberships(
         directory,
         synced_at,
         children_by_group,
         direct_users_by_group
       ) do
    children_group_ids =
      children_by_group
      |> Map.values()
      |> Enum.flat_map(&MapSet.to_list/1)

    group_ids =
      (Map.keys(children_by_group) ++ Map.keys(direct_users_by_group) ++ children_group_ids)
      |> MapSet.new()
      |> MapSet.to_list()

    flattened_users_by_group =
      group_ids
      |> Enum.reduce(%{}, fn group_id, acc ->
        Map.put(acc, group_id, Map.get(direct_users_by_group, group_id, MapSet.new()))
      end)
      |> expand_flattened_users_until_stable(group_ids, children_by_group)

    memberships =
      flattened_users_by_group
      |> Enum.flat_map(fn {group_id, user_ids} ->
        Enum.map(user_ids, fn user_id -> {group_id, user_id} end)
      end)

    upsert_membership_batches(directory, synced_at, memberships)
  end

  defp expand_flattened_users_until_stable(flattened_users_by_group, group_ids, children_by_group) do
    {next, changed?} =
      Enum.reduce(group_ids, {flattened_users_by_group, false}, fn group_id, {acc, changed?} ->
        current_users = Map.get(acc, group_id, MapSet.new())

        expanded_users =
          Map.get(children_by_group, group_id, MapSet.new())
          |> Enum.reduce(current_users, fn child_group_id, users_acc ->
            MapSet.union(users_acc, Map.get(acc, child_group_id, MapSet.new()))
          end)

        if MapSet.equal?(current_users, expanded_users) do
          {acc, changed?}
        else
          {Map.put(acc, group_id, expanded_users), true}
        end
      end)

    if changed? do
      expand_flattened_users_until_stable(next, group_ids, children_by_group)
    else
      next
    end
  end

  defp maybe_enqueue_sub_group(directory, access_token, synced_at, sub_id, {q, v}) do
    if MapSet.member?(v, sub_id) do
      {q, v}
    else
      case fetch_and_upsert_discovered_group(directory, access_token, synced_at, sub_id) do
        :ok -> {:queue.in(sub_id, q), MapSet.put(v, sub_id)}
        :skip -> {q, MapSet.put(v, sub_id)}
      end
    end
  end

  defp enqueue_discovered_sub_groups(
         directory,
         access_token,
         synced_at,
         sub_group_ids,
         queue,
         visited
       ) do
    Enum.reduce(sub_group_ids, {queue, visited}, fn sub_id, acc ->
      maybe_enqueue_sub_group(directory, access_token, synced_at, sub_id, acc)
    end)
  end

  # Fetches and upserts a sub-group discovered during BFS by calling get_group to
  # retrieve its display name and email. Returns :ok on success or :skip if the
  # group no longer exists (404) or is inaccessible (403, e.g. external groups
  # from another domain).
  defp fetch_and_upsert_discovered_group(directory, access_token, synced_at, group_id) do
    Logger.debug("Fetching discovered sub-group",
      google_directory_id: directory.id,
      group_id: group_id
    )

    case Google.APIClient.get_group(access_token, group_id) do
      {:ok, group} ->
        unless group["id"] do
          raise Google.SyncError,
            error: {:validation, "discovered group missing 'id' field"},
            directory_id: directory.id,
            step: :get_group
        end

        unless group["name"] || group["email"] do
          raise Google.SyncError,
            error: {:validation, "discovered group '#{group_id}' missing 'name' field"},
            directory_id: directory.id,
            step: :get_group
        end

        attrs = [
          %{
            idp_id: group["id"],
            name: group["name"] || group["email"],
            email: group["email"]
          }
        ]

        batch_upsert_groups(directory, synced_at, attrs)
        :ok

      {:error, :not_found} ->
        Logger.debug("Discovered sub-group no longer exists in Google, skipping",
          google_directory_id: directory.id,
          group_id: group_id
        )

        :skip

      {:error, :forbidden} ->
        Logger.debug("Discovered sub-group is not accessible (external group?), skipping",
          google_directory_id: directory.id,
          group_id: group_id
        )

        :skip

      {:error, error} ->
        raise Google.SyncError,
          error: error,
          directory_id: directory.id,
          step: :get_group
    end
  end

  # Returns {user_membership_tuples, sub_group_idp_ids}:
  # - user_membership_tuples: [{group_idp_id, user_idp_id}] for type=USER members
  # - sub_group_idp_ids: [idp_id] for type=GROUP members (to be discovered via BFS)
  defp fetch_group_members(directory, access_token, group_idp_id) do
    Logger.debug("Streaming members for group",
      google_directory_id: directory.id,
      group_key: group_idp_id
    )

    Google.APIClient.stream_group_members(access_token, group_idp_id)
    |> Enum.reduce({[], []}, fn
      {:error, error}, _acc ->
        Logger.error("Failed to fetch members for group",
          group_key: group_idp_id,
          error: inspect(error),
          google_directory_id: directory.id
        )

        raise Google.SyncError,
          error: error,
          directory_id: directory.id,
          step: :stream_group_members

      members, {user_acc, sub_group_acc} when is_list(members) ->
        Logger.debug("Received members page",
          google_directory_id: directory.id,
          group_key: group_idp_id,
          count: length(members)
        )

        user_members =
          Enum.filter(members, fn m ->
            m["type"] == "USER" and member_in_domain?(m, directory.domain)
          end)

        group_members = Enum.filter(members, fn m -> m["type"] == "GROUP" end)

        user_tuples =
          Enum.map(user_members, fn member ->
            validate_member!(member, group_idp_id, directory)
            {group_idp_id, member["id"]}
          end)

        sub_group_ids = Enum.flat_map(group_members, fn member -> List.wrap(member["id"]) end)

        {Enum.reverse(user_tuples, user_acc), Enum.reverse(sub_group_ids, sub_group_acc)}
    end)
    |> then(fn {user_acc, sub_group_acc} ->
      {Enum.reverse(user_acc), Enum.reverse(sub_group_acc)}
    end)
  end

  defp validate_group!(group, directory) do
    unless group["id"] do
      raise Google.SyncError,
        error: {:validation, "group missing 'id' field"},
        directory_id: directory.id,
        step: :process_group
    end

    unless group["name"] || group["email"] do
      raise Google.SyncError,
        error: {:validation, "group '#{group["id"]}' missing 'name' field"},
        directory_id: directory.id,
        step: :process_group
    end
  end

  defp validate_org_unit!(org_unit, directory) do
    unless org_unit["orgUnitId"] do
      raise Google.SyncError,
        error: {:validation, "org_unit missing 'orgUnitId' field"},
        directory_id: directory.id,
        step: :process_org_unit
    end

    unless org_unit["name"] do
      raise Google.SyncError,
        error: {:validation, "org_unit '#{org_unit["orgUnitId"]}' missing 'name' field"},
        directory_id: directory.id,
        step: :process_org_unit
    end

    unless org_unit["orgUnitPath"] do
      raise Google.SyncError,
        error: {:validation, "org_unit '#{org_unit["orgUnitId"]}' missing 'orgUnitPath' field"},
        directory_id: directory.id,
        step: :process_org_unit
    end
  end

  defp validate_member!(member, group_idp_id, directory) do
    unless member["id"] do
      raise Google.SyncError,
        error: {:validation, "member missing 'id' field in group #{group_idp_id}"},
        directory_id: directory.id,
        step: :process_member
    end
  end

  defp validate_ou_member!(user, ou_idp_id, directory) do
    unless user["id"] do
      raise Google.SyncError,
        error: {:validation, "user missing 'id' field in org unit #{ou_idp_id}"},
        directory_id: directory.id,
        step: :process_org_unit_member
    end
  end

  defp member_in_domain?(member, domain) do
    case member["email"] do
      email when is_binary(email) ->
        String.ends_with?(String.downcase(email), "@#{String.downcase(domain)}")

      _ ->
        false
    end
  end

  # Phase 3: org unit member sync

  defp sync_org_unit_members_phase(
         directory,
         access_token,
         synced_at,
         org_unit_entries,
         seen_user_ids
       ) do
    Enum.reduce(org_unit_entries, seen_user_ids, fn {ou_idp_id, ou_path}, seen ->
      sync_single_org_unit(directory, access_token, synced_at, ou_idp_id, ou_path, seen)
    end)
  end

  defp sync_single_org_unit(directory, access_token, synced_at, ou_idp_id, ou_path, seen_user_ids) do
    {user_tuples, users_by_id} =
      fetch_org_unit_memberships(directory, access_token, ou_idp_id, ou_path)

    user_ids = user_ids_from_membership_tuples(user_tuples)

    new_user_ids =
      user_ids
      |> Enum.reject(&MapSet.member?(seen_user_ids, &1))

    new_users =
      new_user_ids
      |> Enum.map(&Map.fetch!(users_by_id, &1))

    sync_identities_for_user_payloads(directory, synced_at, new_users)
    upsert_membership_batches(directory, synced_at, user_tuples)

    Enum.reduce(user_ids, seen_user_ids, &MapSet.put(&2, &1))
  end

  defp fetch_org_unit_memberships(directory, access_token, ou_idp_id, ou_path) do
    Logger.debug("Streaming members for organization unit",
      google_directory_id: directory.id,
      org_unit_id: ou_idp_id,
      org_unit_path: ou_path
    )

    Google.APIClient.stream_organization_unit_members(access_token, ou_path)
    |> Enum.reduce({[], %{}}, fn
      {:error, error}, _acc ->
        Logger.error("Failed to fetch users for organization unit",
          org_unit_id: ou_idp_id,
          org_unit_path: ou_path,
          error: inspect(error),
          google_directory_id: directory.id
        )

        raise Google.SyncError,
          error: error,
          directory_id: directory.id,
          step: :stream_org_unit_members

      users, {tuple_acc, users_by_id_acc} when is_list(users) ->
        Logger.debug("Received users page for organization unit",
          google_directory_id: directory.id,
          org_unit_id: ou_idp_id,
          count: length(users)
        )

        tuples =
          Enum.map(users, fn user ->
            validate_ou_member!(user, ou_idp_id, directory)
            {ou_idp_id, user["id"]}
          end)

        users_by_id =
          Enum.reduce(users, users_by_id_acc, fn user, acc ->
            Map.put(acc, user["id"], user)
          end)

        {Enum.reverse(tuples, tuple_acc), users_by_id}
    end)
    |> then(fn {tuple_acc, users_by_id} ->
      {Enum.reverse(tuple_acc), users_by_id}
    end)
  end

  # Identity sync (shared by group BFS and org unit phases)

  defp sync_identities_for_users(_directory, _access_token, _synced_at, []), do: :ok

  defp sync_identities_for_users(directory, access_token, synced_at, user_idp_ids) do
    Logger.debug("Fetching user details for #{length(user_idp_ids)} users via batch API",
      google_directory_id: directory.id
    )

    users =
      case Google.APIClient.batch_get_users(access_token, user_idp_ids) do
        {:ok, users} ->
          users

        {:error, error} ->
          raise Google.SyncError,
            error: error,
            directory_id: directory.id,
            step: :batch_get_users
      end

    identities = Enum.map(users, &map_user_to_identity(&1, directory.id))

    identities
    |> Enum.chunk_every(@db_batch_size)
    |> Enum.each(&batch_upsert_identities(directory, synced_at, &1))
  end

  defp sync_identities_for_user_payloads(_directory, _synced_at, []), do: :ok

  defp sync_identities_for_user_payloads(directory, synced_at, users) do
    identities = Enum.map(users, &map_user_to_identity(&1, directory.id))

    identities
    |> Enum.chunk_every(@db_batch_size)
    |> Enum.each(&batch_upsert_identities(directory, synced_at, &1))
  end

  defp sync_new_user_identities(directory, access_token, synced_at, user_ids, seen_user_ids) do
    new_user_idp_ids =
      user_ids
      |> Enum.reject(&MapSet.member?(seen_user_ids, &1))

    sync_identities_for_users(directory, access_token, synced_at, new_user_idp_ids)

    Enum.reduce(new_user_idp_ids, seen_user_ids, &MapSet.put(&2, &1))
  end

  defp user_ids_from_membership_tuples(user_tuples) do
    user_tuples
    |> Enum.map(fn {_, user_id} -> user_id end)
    |> Enum.uniq()
  end

  defp upsert_membership_batches(_directory, _synced_at, []), do: :ok

  defp upsert_membership_batches(directory, synced_at, memberships) do
    memberships
    |> Enum.chunk_every(@db_batch_size)
    |> Enum.each(&batch_upsert_memberships(directory, synced_at, &1))
  end

  defp map_user_to_identity(user, directory_id) do
    primary_email = user["primaryEmail"]

    unless primary_email do
      raise Google.SyncError,
        error: {:validation, "user '#{user["id"]}' missing 'primaryEmail' field"},
        directory_id: directory_id,
        step: :process_user
    end

    full_name =
      user
      |> Map.get("name", %{})
      |> Map.get("fullName")

    %{
      idp_id: user["id"],
      email: primary_email,
      name: full_name || primary_email,
      given_name: Map.get(user, "name", %{}) |> Map.get("givenName"),
      family_name: Map.get(user, "name", %{}) |> Map.get("familyName"),
      preferred_username: primary_email,
      picture: Map.get(user, "thumbnailPhotoUrl")
    }
  end

  # Cleanup

  defp delete_unsynced(directory, synced_at) do
    account_id = directory.account_id
    directory_id = directory.id

    # Delete memberships before groups (memberships reference groups via FK)
    {count, _} = Database.delete_unsynced_memberships(account_id, directory_id, synced_at)

    Logger.debug("Deleted unsynced memberships",
      google_directory_id: directory.id,
      count: count
    )

    {count, _} = Database.delete_unsynced_groups(account_id, directory_id, synced_at)

    Logger.debug("Deleted unsynced groups and org units",
      google_directory_id: directory.id,
      count: count
    )

    {count, _} = Database.delete_unsynced_identities(account_id, directory_id, synced_at)

    Logger.debug("Deleted unsynced identities",
      google_directory_id: directory.id,
      count: count
    )

    {count, _} = Database.delete_actors_without_identities(account_id, directory_id)

    Logger.debug("Deleted actors without identities",
      google_directory_id: directory.id,
      count: count
    )
  end

  # Batch DB helpers

  @doc false
  def batch_upsert_identities(directory, synced_at, identities) do
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

        raise Google.SyncError,
          error: {:database, "failed to upsert identities: #{inspect(reason)}"},
          directory_id: directory.id,
          step: :batch_upsert_identities
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

  @doc false
  def batch_upsert_memberships(directory, synced_at, memberships) do
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

        raise Google.SyncError,
          error: {:database, "failed to upsert memberships: #{inspect(reason)}"},
          directory_id: directory.id,
          step: :batch_upsert_memberships
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

  defmodule Database do
    import Ecto.Query
    alias Portal.Safe

    @issuer "https://accounts.google.com"

    def get_directory(id) do
      from(d in Google.Directory,
        join: a in Portal.Account,
        on: a.id == d.account_id,
        where: d.id == ^id,
        where: d.is_disabled == false,
        where: is_nil(a.disabled_at)
      )
      |> Safe.unscoped(:replica)
      |> Safe.one(fallback_to_primary: true)
    end

    def update_directory(changeset) do
      changeset |> Safe.unscoped() |> Safe.update()
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

      case Safe.unscoped() |> Safe.query(query, params) do
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
      query = build_group_upsert_query(length(group_attrs))

      params =
        build_group_upsert_params(
          account_id,
          directory_id,
          last_synced_at,
          group_attrs,
          entity_type
        )

      case Safe.unscoped() |> Safe.query(query, params) do
        {:ok, %Postgrex.Result{num_rows: num_rows}} ->
          {:ok, %{upserted_groups: num_rows}}

        {:error, reason} ->
          {:error, reason}
      end
    end

    defp build_group_upsert_query(count) do
      # Each group has 3 fields: idp_id, name, email
      values_clause =
        for i <- 1..count, base = (i - 1) * 3 do
          "($#{base + 1}, $#{base + 2}, $#{base + 3})"
        end
        |> Enum.join(", ")

      offset = count * 3
      account_id = offset + 1
      directory_id = offset + 2
      last_synced_at = offset + 3
      entity_type = offset + 4

      """
      WITH input_data (idp_id, name, email) AS (
        VALUES #{values_clause}
      )
      INSERT INTO groups (
        id, name, email, directory_id, idp_id, account_id,
        inserted_at, updated_at, type, entity_type, last_synced_at
      )
      SELECT
        uuid_generate_v4(),
        id.name,
        id.email,
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
        email = CASE
          WHEN groups.last_synced_at IS NULL OR groups.last_synced_at < EXCLUDED.last_synced_at
          THEN EXCLUDED.email
          ELSE groups.email
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
          [attrs.idp_id, attrs.name, Map.get(attrs, :email)]
        end)

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

      result =
        try do
          Safe.unscoped() |> Safe.query(query, params)
        rescue
          error in DBConnection.EncodeError -> {:error, error}
        end

      case result do
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
end
