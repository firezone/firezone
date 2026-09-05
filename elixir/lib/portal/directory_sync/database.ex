defmodule Portal.DirectorySync.Database do
  @moduledoc false
  import Ecto.Query
  alias Portal.Safe

  @identity_fields ~w[idp_id email name given_name family_name preferred_username]a
  @tombstone_quarantine_seconds 15 * 60
  @tombstone_grace_seconds 60 * 60

  def batch_upsert_identities(_account_id, _issuer, _directory_id, _synced_at, [], _opts),
    do: {:ok, %{upserted_identities: 0}}

  def batch_upsert_identities(account_id, issuer, directory_id, synced_at, attrs, opts) do
    fields = @identity_fields ++ Keyword.get(opts, :fields, [])
    eligible? = Keyword.get(opts, :eligible, true)
    quarantine? = Keyword.get(opts, :quarantine, false)
    query = identity_upsert_query(length(attrs), fields, eligible?, quarantine?)

    params =
      Enum.flat_map(attrs, fn identity -> Enum.map(fields, &Map.get(identity, &1)) end) ++
        [Ecto.UUID.dump!(account_id), issuer, Ecto.UUID.dump!(directory_id), synced_at]

    run_identity_upsert(query, params)
  end

  def batch_upsert_groups(_account_id, _directory_id, _synced_at, [], _entity_type),
    do: {:ok, %{upserted_groups: 0}}

  def batch_upsert_groups(account_id, directory_id, synced_at, attrs, entity_type) do
    query = group_upsert_query(length(attrs))

    params =
      Enum.flat_map(attrs, fn group -> [group.idp_id, group.name, Map.get(group, :email)] end) ++
        [
          Ecto.UUID.dump!(account_id),
          Ecto.UUID.dump!(directory_id),
          synced_at,
          to_string(entity_type)
        ]

    case Safe.unscoped() |> Safe.query(query, params) do
      {:ok, %Postgrex.Result{num_rows: num_rows}} -> {:ok, %{upserted_groups: num_rows}}
      {:error, reason} -> {:error, reason}
    end
  end

  def batch_upsert_memberships(_account_id, _issuer, _directory_id, _synced_at, []),
    do: {:ok, %{upserted_memberships: 0}}

  # The rows are stamped in a second statement so a membership another writer
  # inserted while this one waited is stamped too instead of being left for
  # the cleanup to delete.
  def batch_upsert_memberships(account_id, issuer, directory_id, synced_at, tuples) do
    tuples = Enum.uniq(tuples)
    account_uuid = Ecto.UUID.dump!(account_id)
    query = membership_insert_query(length(tuples))

    params =
      Enum.flat_map(tuples, fn {group_idp_id, user_idp_id} -> [group_idp_id, user_idp_id] end) ++
        [account_uuid, issuer, Ecto.UUID.dump!(directory_id), synced_at]

    Safe.unscoped()
    |> Safe.transaction(fn ->
      with {:ok, %Postgrex.Result{rows: pairs}} <- query(query, params),
           {actor_ids, group_ids} = Enum.unzip(Enum.map(pairs, &List.to_tuple/1)),
           {:ok, %Postgrex.Result{num_rows: num_rows}} <-
             query(membership_stamp_query(), [account_uuid, actor_ids, group_ids, synced_at]) do
        {:ok, %{upserted_memberships: num_rows}}
      end
    end)
  end

  @doc """
  Tombstones one identity key and, unless a newer write claimed it, removes
  the identity that currently holds the key along with its memberships in
  this directory. Works without a local identity, so a user deleted before
  the full sync inserted them still leaves a tombstone behind.
  """
  def remove_identity(account_id, directory_id, issuer, idp_id, synced_at) do
    account_uuid = Ecto.UUID.dump!(account_id)
    directory_uuid = Ecto.UUID.dump!(directory_id)

    Safe.unscoped()
    |> Safe.transaction(fn ->
      with {:ok, %Postgrex.Result{num_rows: 1}} <-
             query(identity_tombstone_query(), [account_uuid, directory_uuid, idp_id, synced_at]),
           {:ok, %Postgrex.Result{num_rows: num_rows}} <-
             query(identity_delete_query(), [account_uuid, directory_uuid, issuer, idp_id]) do
        {:ok, num_rows}
      else
        {:ok, %Postgrex.Result{num_rows: 0}} -> {:ok, 0}
        {:error, reason} -> {:error, reason}
      end
    end)
    |> unwrap_count()
  end

  @doc """
  Tombstones one group key and, unless a newer write claimed it, removes the
  group that currently holds the key with its memberships. Also serves as a
  fence for a group this directory has not inserted yet.
  """
  def remove_group(account_id, directory_id, idp_id, synced_at) do
    account_uuid = Ecto.UUID.dump!(account_id)
    directory_uuid = Ecto.UUID.dump!(directory_id)

    Safe.unscoped()
    |> Safe.transaction(fn ->
      with {:ok, %Postgrex.Result{num_rows: 1}} <-
             query(group_tombstone_query(), [account_uuid, directory_uuid, idp_id, synced_at]),
           {:ok, %Postgrex.Result{num_rows: num_rows}} <-
             query(group_delete_query(), [account_uuid, directory_uuid, idp_id]) do
        {:ok, num_rows}
      else
        {:ok, %Postgrex.Result{num_rows: 0}} -> {:ok, 0}
        {:error, reason} -> {:error, reason}
      end
    end)
    |> unwrap_count()
  end

  @doc """
  Marks a rewrite of one user's org unit memberships, so org unit membership
  writes older than `synced_at` are skipped for that user from now on.
  """
  def stamp_identity_org_unit_memberships(account_id, directory_id, idp_id, synced_at) do
    from(s in Portal.DirectorySync.IdentityState,
      where: s.account_id == ^account_id,
      where: s.directory_id == ^directory_id,
      where: s.idp_id == ^idp_id,
      where:
        is_nil(s.org_unit_memberships_synced_at) or
          s.org_unit_memberships_synced_at < ^synced_at
    )
    |> Safe.unscoped()
    |> Safe.update_all(set: [org_unit_memberships_synced_at: synced_at])
  end

  def delete_unsynced_identities(account_id, directory_id, synced_at) do
    delete_stale(
      identity_cleanup_tombstone_query(),
      identity_cleanup_delete_query(),
      account_id,
      directory_id,
      synced_at
    )
  end

  def delete_unsynced_groups(account_id, directory_id, synced_at) do
    delete_stale(
      group_cleanup_tombstone_query(),
      group_cleanup_delete_query(),
      account_id,
      directory_id,
      synced_at
    )
  end

  def delete_unsynced_memberships(account_id, directory_id, synced_at) do
    from(m in Portal.Membership,
      join: g in Portal.Group,
      on: m.group_id == g.id and m.account_id == g.account_id,
      where: g.account_id == ^account_id,
      where: g.directory_id == ^directory_id,
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

  def delete_actors_without_identities(account_id, directory_id) do
    from(a in Portal.Actor,
      where: a.account_id == ^account_id,
      where: a.created_by_directory_id == ^directory_id,
      where:
        fragment(
          "NOT EXISTS (SELECT 1 FROM external_identities WHERE actor_id = ?)",
          a.id
        )
    )
    |> Safe.unscoped()
    |> Safe.delete_all()
  end

  @doc """
  Drops tombstones older than both the previous completed full sync and the
  webhook job timeout, so no writer that is still running can carry an older
  timestamp.
  """
  def prune_tombstones(account_id, directory_id, previous_run_started_at) do
    grace = DateTime.add(DateTime.utc_now(), -@tombstone_grace_seconds, :second)
    before = Enum.min([previous_run_started_at, grace], DateTime)

    from(s in Portal.DirectorySync.IdentityState,
      where: s.account_id == ^account_id,
      where: s.directory_id == ^directory_id,
      where: s.synced_at < ^before,
      where: is_nil(s.eligible_at) or s.eligible_at < ^before,
      where: is_nil(s.memberships_synced_at) or s.memberships_synced_at < ^before,
      where:
        is_nil(s.org_unit_memberships_synced_at) or s.org_unit_memberships_synced_at < ^before,
      where:
        fragment(
          "NOT EXISTS (SELECT 1 FROM external_identities ei WHERE ei.account_id = ? AND ei.directory_id = ? AND ei.idp_id = ?)",
          s.account_id,
          s.directory_id,
          s.idp_id
        )
    )
    |> Safe.unscoped()
    |> Safe.delete_all()

    from(s in Portal.DirectorySync.GroupState,
      where: s.account_id == ^account_id,
      where: s.directory_id == ^directory_id,
      where: s.synced_at < ^before,
      where: is_nil(s.memberships_synced_at) or s.memberships_synced_at < ^before,
      where:
        fragment(
          "NOT EXISTS (SELECT 1 FROM groups g WHERE g.account_id = ? AND g.directory_id = ? AND g.idp_id = ?)",
          s.account_id,
          s.directory_id,
          s.idp_id
        )
    )
    |> Safe.unscoped()
    |> Safe.delete_all()

    :ok
  end

  def full_sync_running?(worker, directory_id) do
    from(j in Oban.Job,
      where: j.worker == ^inspect(worker),
      where: j.state == "executing",
      where: fragment("?->>'directory_id' = ?", j.args, ^directory_id)
    )
    |> Safe.unscoped()
    |> Safe.exists?()
  end

  def tombstone_grace_seconds, do: @tombstone_grace_seconds

  defp delete_stale(tombstone_query, delete_query, account_id, directory_id, synced_at) do
    account_uuid = Ecto.UUID.dump!(account_id)
    directory_uuid = Ecto.UUID.dump!(directory_id)

    Safe.unscoped()
    |> Safe.transaction(fn ->
      with {:ok, %Postgrex.Result{rows: rows}} <-
             query(tombstone_query, [account_uuid, directory_uuid, synced_at]),
           idp_ids = List.flatten(rows),
           {:ok, %Postgrex.Result{num_rows: num_rows}} <-
             query(delete_query, [account_uuid, directory_uuid, idp_ids]) do
        {:ok, num_rows}
      end
    end)
    |> unwrap_count()
  end

  defp unwrap_count({:ok, count}), do: {count, nil}
  defp unwrap_count({:error, reason}), do: raise(reason)

  defp query(sql, params) do
    Safe.unscoped() |> Safe.query(sql, params)
  rescue
    error in DBConnection.EncodeError -> {:error, error}
  end

  # A concurrent OIDC sign-in can insert an identity for the same
  # (account_id, idp_id, issuer) after this statement's snapshot is taken,
  # which the (account_id, id) conflict target does not handle. Re-running
  # picks up the now-committed row via pre_existing_identities and recycles
  # it, so we retry once before surfacing the error.
  defp run_identity_upsert(query, params, retry? \\ true) do
    case Safe.unscoped() |> Safe.query(query, params) do
      {:ok, %Postgrex.Result{num_rows: num_rows}} ->
        {:ok, %{upserted_identities: num_rows}}

      {:error, %Postgrex.Error{postgres: %{code: :unique_violation}}} when retry? ->
        run_identity_upsert(query, params, false)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp identity_upsert_query(count, fields, eligible?, quarantine?) do
    width = length(fields)

    values_clause =
      Enum.map_join(1..count, ", ", fn i ->
        base = (i - 1) * width
        "(" <> Enum.map_join(1..width, ", ", &"$#{base + &1}") <> ")"
      end)

    offset = count * width
    account_id = offset + 1
    issuer = offset + 2
    directory_id = offset + 3
    synced_at = offset + 4

    profile_fields = fields -- [:idp_id]
    columns = Enum.join(fields, ", ")
    profile_columns = Enum.join(profile_fields, ", ")
    input_profile = Enum.map_join(profile_fields, ", ", &"id.#{&1}")
    mapped_profile = Enum.map_join(profile_fields, ", ", &"aam.#{&1}")
    set_profile = Enum.map_join(profile_fields, ",\n        ", &"#{&1} = EXCLUDED.#{&1}")
    compared = [:idp_id, :issuer, :directory_id] ++ profile_fields
    current_values = Enum.map_join(compared, ", ", &"external_identities.#{&1}")
    excluded_values = Enum.map_join(compared, ", ", &"EXCLUDED.#{&1}")

    eligible_at =
      if eligible? do
        "$#{synced_at}"
      else
        "NULL::timestamptz"
      end

    # A group member listing lags behind a deletion, so it may not revive a
    # tombstone written moments ago. A direct read of the user may.
    claim_source =
      if quarantine? do
        """
        FROM input_data
        WHERE idp_id NOT IN (
          SELECT s.idp_id
          FROM directory_identity_sync_states s
          WHERE s.account_id = $#{account_id}
            AND s.directory_id = $#{directory_id}
            AND s.idp_id IN (SELECT idp_id FROM input_data)
            AND s.synced_at > $#{synced_at}::timestamptz - interval '#{@tombstone_quarantine_seconds} seconds'
            AND NOT EXISTS (
              SELECT 1 FROM external_identities ei
              WHERE ei.account_id = s.account_id
                AND ei.directory_id = s.directory_id
                AND ei.idp_id = s.idp_id
            )
        )
        """
      else
        "FROM input_data"
      end

    """
    WITH input_data AS (
      SELECT * FROM (VALUES #{values_clause})
      AS t(#{columns})
    ),
    claimed AS (
      INSERT INTO directory_identity_sync_states
        (account_id, directory_id, idp_id, synced_at, eligible_at)
      SELECT $#{account_id}, $#{directory_id}, idp_id, $#{synced_at}, #{eligible_at}
      #{claim_source}
      ORDER BY idp_id
      ON CONFLICT (account_id, directory_id, idp_id) DO UPDATE SET
        synced_at = EXCLUDED.synced_at,
        eligible_at = GREATEST(directory_identity_sync_states.eligible_at, EXCLUDED.eligible_at)
      WHERE directory_identity_sync_states.synced_at < EXCLUDED.synced_at
      RETURNING idp_id
    ),
    winners AS (
      SELECT id.*
      FROM input_data id
      JOIN claimed c ON c.idp_id = id.idp_id
    ),
    pre_existing_identities AS (
      SELECT ei.id, ei.account_id, ei.actor_id, ei.idp_id
      FROM external_identities ei
      WHERE ei.account_id = $#{account_id}
        AND ei.issuer = $#{issuer}
        AND ei.idp_id IN (SELECT idp_id FROM winners)
    ),
    existing_actors_by_email AS (
      SELECT DISTINCT ON (id.idp_id) a.id AS actor_id, id.idp_id
      FROM winners id
      JOIN actors a ON a.email = id.email AND a.account_id = $#{account_id}
      WHERE id.idp_id NOT IN (SELECT idp_id FROM pre_existing_identities)
        AND id.email IS NOT NULL
      ORDER BY id.idp_id, a.inserted_at ASC
    ),
    -- Recycles the actor's existing identity for this directory so a changed
    -- idp_id (issuer unchanged) or a changed issuer (directory reverified
    -- against a new tenant) updates the row in place instead of inserting a
    -- second one and tripping the (account_id, actor_id, issuer) unique index.
    -- Matching on issuer OR directory_id covers both: issuer alone catches
    -- legacy rows whose directory_id is NULL or differs; directory_id alone
    -- catches the row whose issuer just changed. DISTINCT ON keeps one row per
    -- actor, preferring the row that already holds the new issuer so updating
    -- it cannot collide on that index.
    existing_directory_identities AS (
      SELECT DISTINCT ON (ei.actor_id) ei.id, ei.actor_id
      FROM external_identities ei
      WHERE ei.account_id = $#{account_id}
        AND ei.actor_id IN (SELECT actor_id FROM existing_actors_by_email)
        AND (ei.issuer = $#{issuer} OR ei.directory_id = $#{directory_id})
      ORDER BY ei.actor_id, (ei.issuer = $#{issuer}) DESC
    ),
    actors_to_create AS (
      SELECT
        uuid_generate_v4() AS new_actor_id,
        id.idp_id,
        id.name,
        id.email
      FROM winners id
      WHERE id.idp_id NOT IN (SELECT idp_id FROM pre_existing_identities)
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
        $#{synced_at},
        $#{synced_at}
      FROM actors_to_create
      RETURNING id, name
    ),
    all_actor_mappings AS (
      SELECT atc.new_actor_id AS actor_id, atc.idp_id, #{input_profile}
      FROM actors_to_create atc
      JOIN winners id ON id.idp_id = atc.idp_id
      UNION ALL
      SELECT ei.actor_id, ei.idp_id, #{input_profile}
      FROM pre_existing_identities ei
      JOIN winners id ON id.idp_id = ei.idp_id
      UNION ALL
      SELECT eabe.actor_id, eabe.idp_id, #{input_profile}
      FROM existing_actors_by_email eabe
      JOIN winners id ON id.idp_id = eabe.idp_id
    ),
    upserted_identities AS (
      INSERT INTO external_identities (
        id, actor_id, issuer, idp_id, directory_id, #{profile_columns},
        account_id, inserted_at, updated_at
      )
      SELECT
        COALESCE(ei.id, edi.id, uuid_generate_v4()),
        aam.actor_id,
        $#{issuer},
        aam.idp_id,
        $#{directory_id},
        #{mapped_profile},
        $#{account_id},
        $#{synced_at},
        $#{synced_at}
      FROM all_actor_mappings aam
      LEFT JOIN pre_existing_identities ei ON ei.idp_id = aam.idp_id
      LEFT JOIN existing_directory_identities edi ON edi.actor_id = aam.actor_id
      ON CONFLICT (account_id, id)
      DO UPDATE SET
        idp_id = EXCLUDED.idp_id,
        issuer = EXCLUDED.issuer,
        directory_id = EXCLUDED.directory_id,
        #{set_profile},
        updated_at = EXCLUDED.updated_at
      WHERE (#{current_values})
            IS DISTINCT FROM
            (#{excluded_values})
      RETURNING id
    )
    SELECT idp_id FROM claimed
    """
  end

  defp group_upsert_query(count) do
    values_clause =
      Enum.map_join(1..count, ", ", fn i ->
        base = (i - 1) * 3
        "($#{base + 1}, $#{base + 2}, $#{base + 3})"
      end)

    offset = count * 3
    account_id = offset + 1
    directory_id = offset + 2
    synced_at = offset + 3
    entity_type = offset + 4

    """
    WITH input_data (idp_id, name, email) AS (
      VALUES #{values_clause}
    ),
    claimed AS (
      INSERT INTO directory_group_sync_states
        (account_id, directory_id, idp_id, synced_at, memberships_synced_at)
      SELECT $#{account_id}, $#{directory_id}, idp_id, $#{synced_at}, $#{synced_at}
      FROM input_data
      ORDER BY idp_id
      ON CONFLICT (account_id, directory_id, idp_id) DO UPDATE SET
        synced_at = EXCLUDED.synced_at,
        memberships_synced_at = GREATEST(
          directory_group_sync_states.memberships_synced_at,
          EXCLUDED.memberships_synced_at
        )
      WHERE directory_group_sync_states.synced_at < EXCLUDED.synced_at
      RETURNING idp_id
    ),
    winners AS (
      SELECT id.*
      FROM input_data id
      JOIN claimed c ON c.idp_id = id.idp_id
    ),
    upserted_groups AS (
      INSERT INTO groups (
        id, name, email, directory_id, idp_id, account_id,
        inserted_at, updated_at, type, entity_type
      )
      SELECT
        uuid_generate_v4(),
        id.name,
        id.email,
        $#{directory_id},
        id.idp_id,
        $#{account_id},
        $#{synced_at},
        $#{synced_at},
        'static',
        $#{entity_type}
      FROM winners id
      ON CONFLICT (account_id, idp_id) WHERE idp_id IS NOT NULL
      DO UPDATE SET
        name = EXCLUDED.name,
        email = EXCLUDED.email,
        directory_id = EXCLUDED.directory_id,
        entity_type = EXCLUDED.entity_type,
        updated_at = EXCLUDED.updated_at
      WHERE (groups.name, groups.email, groups.directory_id, groups.entity_type)
            IS DISTINCT FROM
            (EXCLUDED.name, EXCLUDED.email, EXCLUDED.directory_id, EXCLUDED.entity_type)
      RETURNING id
    )
    SELECT idp_id FROM claimed
    """
  end

  # The guards lock the group's and the user's state rows, so a concurrent
  # list rewrite must wait for this statement and then sees its rows.
  defp membership_insert_query(count) do
    values_clause =
      Enum.map_join(1..count, ", ", fn i ->
        base = (i - 1) * 2
        "($#{base + 1}, $#{base + 2})"
      end)

    offset = count * 2
    account_id = offset + 1
    issuer = offset + 2
    directory_id = offset + 3
    synced_at = offset + 4

    """
    WITH membership_input AS (
      SELECT * FROM (VALUES #{values_clause})
      AS t(group_idp_id, user_idp_id)
    ),
    group_guards AS (
      SELECT idp_id, memberships_synced_at
      FROM directory_group_sync_states
      WHERE account_id = $#{account_id}
        AND directory_id = $#{directory_id}
        AND idp_id IN (SELECT group_idp_id FROM membership_input)
      ORDER BY idp_id
      FOR SHARE
    ),
    identity_guards AS (
      SELECT idp_id, memberships_synced_at, org_unit_memberships_synced_at
      FROM directory_identity_sync_states
      WHERE account_id = $#{account_id}
        AND directory_id = $#{directory_id}
        AND idp_id IN (SELECT user_idp_id FROM membership_input)
      ORDER BY idp_id
      FOR SHARE
    ),
    resolved_memberships AS (
      SELECT DISTINCT
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
      LEFT JOIN group_guards gg ON gg.idp_id = mi.group_idp_id
      LEFT JOIN identity_guards ig ON ig.idp_id = mi.user_idp_id
      WHERE (gg.memberships_synced_at IS NULL OR gg.memberships_synced_at <= $#{synced_at})
        AND (ig.memberships_synced_at IS NULL OR ig.memberships_synced_at <= $#{synced_at})
        AND (
          ag.entity_type <> 'org_unit'
          OR ig.org_unit_memberships_synced_at IS NULL
          OR ig.org_unit_memberships_synced_at <= $#{synced_at}
        )
    ),
    new_memberships AS (
      INSERT INTO memberships (id, actor_id, group_id, account_id)
      SELECT
        uuid_generate_v4(),
        rm.actor_id,
        rm.group_id,
        $#{account_id} AS account_id
      FROM resolved_memberships rm
      WHERE NOT EXISTS (
        SELECT 1 FROM memberships m
        WHERE m.account_id = $#{account_id}
          AND m.actor_id = rm.actor_id
          AND m.group_id = rm.group_id
      )
      ON CONFLICT (actor_id, group_id) DO NOTHING
      RETURNING id
    )
    SELECT actor_id, group_id FROM resolved_memberships
    """
  end

  defp membership_stamp_query do
    """
    INSERT INTO membership_sync_states (account_id, membership_id, synced_at)
    SELECT m.account_id, m.id, $4
    FROM memberships m
    JOIN unnest($2::uuid[], $3::uuid[]) AS p(actor_id, group_id)
      ON p.actor_id = m.actor_id AND p.group_id = m.group_id
    WHERE m.account_id = $1
    ON CONFLICT (account_id, membership_id) DO UPDATE SET
      synced_at = EXCLUDED.synced_at
    WHERE membership_sync_states.synced_at < EXCLUDED.synced_at
    RETURNING 1
    """
  end

  # Removes claim on an equal timestamp too: a webhook job upserts the user it
  # re-read and then removes them with the same timestamp when they turn out
  # to have left every tracked group or org unit.
  defp identity_tombstone_query do
    """
    INSERT INTO directory_identity_sync_states
      (account_id, directory_id, idp_id, synced_at, memberships_synced_at)
    VALUES ($1, $2, $3, $4, $4)
    ON CONFLICT (account_id, directory_id, idp_id) DO UPDATE SET
      synced_at = EXCLUDED.synced_at,
      memberships_synced_at = GREATEST(
        directory_identity_sync_states.memberships_synced_at,
        EXCLUDED.memberships_synced_at
      )
    WHERE directory_identity_sync_states.synced_at <= EXCLUDED.synced_at
    RETURNING idp_id
    """
  end

  defp identity_delete_query do
    """
    WITH identity AS (
      SELECT ei.id, ei.actor_id
      FROM external_identities ei
      WHERE ei.account_id = $1
        AND ei.idp_id = $4
        AND (ei.directory_id = $2 OR ei.issuer = $3)
    ),
    deleted_memberships AS (
      DELETE FROM memberships m
      USING identity i, groups g
      WHERE m.account_id = $1
        AND m.actor_id = i.actor_id
        AND g.account_id = m.account_id
        AND g.id = m.group_id
        AND g.directory_id = $2
      RETURNING m.id
    )
    DELETE FROM external_identities ei
    USING identity i
    WHERE ei.account_id = $1 AND ei.id = i.id
    """
  end

  defp group_tombstone_query do
    """
    INSERT INTO directory_group_sync_states
      (account_id, directory_id, idp_id, synced_at, memberships_synced_at)
    VALUES ($1, $2, $3, $4, $4)
    ON CONFLICT (account_id, directory_id, idp_id) DO UPDATE SET
      synced_at = EXCLUDED.synced_at,
      memberships_synced_at = GREATEST(
        directory_group_sync_states.memberships_synced_at,
        EXCLUDED.memberships_synced_at
      )
    WHERE directory_group_sync_states.synced_at <= EXCLUDED.synced_at
    RETURNING idp_id
    """
  end

  defp group_delete_query do
    """
    DELETE FROM groups g
    WHERE g.account_id = $1 AND g.directory_id = $2 AND g.idp_id = $3
    """
  end

  # An identity kept alive by a webhook that only re-read the user still goes
  # when no listing confirmed it during this run.
  defp identity_cleanup_tombstone_query do
    """
    WITH stale AS (
      SELECT ei.idp_id
      FROM external_identities ei
      LEFT JOIN directory_identity_sync_states s
        ON s.account_id = ei.account_id
        AND s.directory_id = ei.directory_id
        AND s.idp_id = ei.idp_id
      WHERE ei.account_id = $1
        AND ei.directory_id = $2
        AND ei.idp_id IS NOT NULL
        AND (s.eligible_at IS NULL OR s.eligible_at < $3)
    )
    INSERT INTO directory_identity_sync_states (account_id, directory_id, idp_id, synced_at)
    SELECT $1, $2, idp_id, $3 FROM stale ORDER BY idp_id
    ON CONFLICT (account_id, directory_id, idp_id) DO UPDATE SET
      synced_at = GREATEST(directory_identity_sync_states.synced_at, EXCLUDED.synced_at)
    WHERE directory_identity_sync_states.eligible_at IS NULL
      OR directory_identity_sync_states.eligible_at < EXCLUDED.synced_at
    RETURNING idp_id
    """
  end

  defp identity_cleanup_delete_query do
    """
    DELETE FROM external_identities ei
    WHERE ei.account_id = $1 AND ei.directory_id = $2 AND ei.idp_id = ANY($3::text[])
    """
  end

  defp group_cleanup_tombstone_query do
    """
    WITH stale AS (
      SELECT g.idp_id
      FROM groups g
      LEFT JOIN directory_group_sync_states s
        ON s.account_id = g.account_id
        AND s.directory_id = g.directory_id
        AND s.idp_id = g.idp_id
      WHERE g.account_id = $1
        AND g.directory_id = $2
        AND g.idp_id IS NOT NULL
        AND (s.synced_at IS NULL OR s.synced_at < $3)
    )
    INSERT INTO directory_group_sync_states (account_id, directory_id, idp_id, synced_at)
    SELECT $1, $2, idp_id, $3 FROM stale ORDER BY idp_id
    ON CONFLICT (account_id, directory_id, idp_id) DO UPDATE SET
      synced_at = EXCLUDED.synced_at
    WHERE directory_group_sync_states.synced_at < EXCLUDED.synced_at
    RETURNING idp_id
    """
  end

  defp group_cleanup_delete_query do
    """
    DELETE FROM groups g
    WHERE g.account_id = $1 AND g.directory_id = $2 AND g.idp_id = ANY($3::text[])
    """
  end
end
