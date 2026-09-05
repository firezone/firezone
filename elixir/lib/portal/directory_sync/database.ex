defmodule Portal.DirectorySync.Database do
  @moduledoc false
  import Ecto.Query
  alias Portal.Safe

  @identity_fields ~w[idp_id email name given_name family_name preferred_username]a

  def batch_upsert_identities(_account_id, _issuer, _directory_id, _synced_at, [], _extra_fields),
    do: {:ok, %{upserted_identities: 0}}

  def batch_upsert_identities(account_id, issuer, directory_id, synced_at, attrs, extra_fields) do
    fields = @identity_fields ++ extra_fields
    query = identity_upsert_query(length(attrs), fields)

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

  def batch_upsert_memberships(account_id, issuer, directory_id, synced_at, tuples) do
    query = membership_upsert_query(length(tuples))

    params =
      Enum.flat_map(tuples, fn {group_idp_id, user_idp_id} -> [group_idp_id, user_idp_id] end) ++
        [Ecto.UUID.dump!(account_id), issuer, Ecto.UUID.dump!(directory_id), synced_at]

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

  @doc """
  Removes one identity and its memberships in this directory unless a newer
  write already claimed the user. The tombstone also stamps the user's
  membership list, so an older membership write cannot re-add one.
  """
  def remove_identity(account_id, directory_id, identity, synced_at) do
    query = """
    WITH claimed AS (
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
    ),
    deleted_memberships AS (
      DELETE FROM memberships m
      USING groups g, claimed
      WHERE m.account_id = $1
        AND m.actor_id = $6
        AND g.account_id = m.account_id
        AND g.id = m.group_id
        AND g.directory_id = $2
      RETURNING m.id
    )
    DELETE FROM external_identities ei
    USING claimed
    WHERE ei.account_id = $1 AND ei.id = $5
    """

    params = [
      Ecto.UUID.dump!(account_id),
      Ecto.UUID.dump!(directory_id),
      identity.idp_id,
      synced_at,
      Ecto.UUID.dump!(identity.id),
      Ecto.UUID.dump!(identity.actor_id)
    ]

    {:ok, %Postgrex.Result{num_rows: num_rows}} = Safe.unscoped() |> Safe.query(query, params)
    {num_rows, nil}
  end

  @doc """
  Removes one group and its memberships unless a newer write already claimed it.
  """
  def remove_group(account_id, directory_id, group, synced_at) do
    query = """
    WITH claimed AS (
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
    )
    DELETE FROM groups g
    USING claimed
    WHERE g.account_id = $1 AND g.id = $5
    """

    params = [
      Ecto.UUID.dump!(account_id),
      Ecto.UUID.dump!(directory_id),
      group.idp_id,
      synced_at,
      Ecto.UUID.dump!(group.id)
    ]

    {:ok, %Postgrex.Result{num_rows: num_rows}} = Safe.unscoped() |> Safe.query(query, params)
    {num_rows, nil}
  end

  @doc """
  Marks a rewrite of one user's whole membership list, so membership writes
  older than `synced_at` are skipped for that user from now on.
  """
  def stamp_identity_memberships(account_id, directory_id, idp_id, synced_at) do
    from(s in Portal.DirectorySync.IdentityState,
      where: s.account_id == ^account_id,
      where: s.directory_id == ^directory_id,
      where: s.idp_id == ^idp_id,
      where: is_nil(s.memberships_synced_at) or s.memberships_synced_at < ^synced_at
    )
    |> Safe.unscoped()
    |> Safe.update_all(set: [memberships_synced_at: synced_at])
  end

  def delete_unsynced_identities(account_id, directory_id, synced_at) do
    query = """
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
        AND (s.synced_at IS NULL OR s.synced_at < $3)
    ),
    tombstoned AS (
      INSERT INTO directory_identity_sync_states (account_id, directory_id, idp_id, synced_at)
      SELECT $1, $2, idp_id, $3 FROM stale ORDER BY idp_id
      ON CONFLICT (account_id, directory_id, idp_id) DO UPDATE SET
        synced_at = EXCLUDED.synced_at
      WHERE directory_identity_sync_states.synced_at < EXCLUDED.synced_at
      RETURNING idp_id
    )
    DELETE FROM external_identities ei
    USING tombstoned t
    WHERE ei.account_id = $1 AND ei.directory_id = $2 AND ei.idp_id = t.idp_id
    """

    delete_stale(query, account_id, directory_id, synced_at)
  end

  def delete_unsynced_groups(account_id, directory_id, synced_at) do
    query = """
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
    ),
    tombstoned AS (
      INSERT INTO directory_group_sync_states (account_id, directory_id, idp_id, synced_at)
      SELECT $1, $2, idp_id, $3 FROM stale ORDER BY idp_id
      ON CONFLICT (account_id, directory_id, idp_id) DO UPDATE SET
        synced_at = EXCLUDED.synced_at
      WHERE directory_group_sync_states.synced_at < EXCLUDED.synced_at
      RETURNING idp_id
    )
    DELETE FROM groups g
    USING tombstoned t
    WHERE g.account_id = $1 AND g.directory_id = $2 AND g.idp_id = t.idp_id
    """

    delete_stale(query, account_id, directory_id, synced_at)
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
  Drops tombstones older than `before`, the start of the previous completed
  full sync, since no writer alive now can carry an older timestamp.
  """
  def prune_tombstones(account_id, directory_id, before) do
    from(s in Portal.DirectorySync.IdentityState,
      where: s.account_id == ^account_id,
      where: s.directory_id == ^directory_id,
      where: s.synced_at < ^before,
      where: is_nil(s.memberships_synced_at) or s.memberships_synced_at < ^before,
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

  defp delete_stale(query, account_id, directory_id, synced_at) do
    params = [Ecto.UUID.dump!(account_id), Ecto.UUID.dump!(directory_id), synced_at]
    {:ok, %Postgrex.Result{num_rows: num_rows}} = Safe.unscoped() |> Safe.query(query, params)
    {num_rows, nil}
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

  defp identity_upsert_query(count, fields) do
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

    """
    WITH input_data AS (
      SELECT * FROM (VALUES #{values_clause})
      AS t(#{columns})
    ),
    claimed AS (
      INSERT INTO directory_identity_sync_states (account_id, directory_id, idp_id, synced_at)
      SELECT $#{account_id}, $#{directory_id}, idp_id, $#{synced_at}
      FROM input_data
      ORDER BY idp_id
      ON CONFLICT (account_id, directory_id, idp_id) DO UPDATE SET
        synced_at = EXCLUDED.synced_at
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

  # Existing memberships are read but never re-written, so unchanged rows
  # produce no WAL. The guards lock the group's and the user's state rows, so a
  # concurrent list rewrite must wait for this statement and then sees its rows.
  defp membership_upsert_query(count) do
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
      SELECT idp_id, memberships_synced_at
      FROM directory_identity_sync_states
      WHERE account_id = $#{account_id}
        AND directory_id = $#{directory_id}
        AND idp_id IN (SELECT user_idp_id FROM membership_input)
      ORDER BY idp_id
      FOR SHARE
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
      LEFT JOIN group_guards gg ON gg.idp_id = mi.group_idp_id
      LEFT JOIN identity_guards ig ON ig.idp_id = mi.user_idp_id
      WHERE (gg.memberships_synced_at IS NULL OR gg.memberships_synced_at <= $#{synced_at})
        AND (ig.memberships_synced_at IS NULL OR ig.memberships_synced_at <= $#{synced_at})
    ),
    existing_memberships AS (
      SELECT m.id, m.account_id, m.actor_id, m.group_id
      FROM memberships m
      WHERE m.account_id = $#{account_id}
        AND (m.actor_id, m.group_id) IN (SELECT actor_id, group_id FROM resolved_memberships)
    ),
    new_memberships AS (
      INSERT INTO memberships (id, actor_id, group_id, account_id)
      SELECT
        uuid_generate_v4(),
        rm.actor_id,
        rm.group_id,
        $#{account_id} AS account_id
      FROM resolved_memberships rm
      WHERE (rm.actor_id, rm.group_id) NOT IN (SELECT actor_id, group_id FROM existing_memberships)
      ON CONFLICT (actor_id, group_id) DO NOTHING
      RETURNING id, account_id
    ),
    all_membership_ids AS (
      SELECT id, account_id FROM new_memberships
      UNION
      SELECT id, account_id FROM existing_memberships
    )
    INSERT INTO membership_sync_states (account_id, membership_id, synced_at)
    SELECT account_id, id, $#{synced_at} FROM all_membership_ids
    ON CONFLICT (account_id, membership_id) DO UPDATE SET
      synced_at = EXCLUDED.synced_at
    WHERE membership_sync_states.synced_at < EXCLUDED.synced_at
    RETURNING 1
    """
  end
end
