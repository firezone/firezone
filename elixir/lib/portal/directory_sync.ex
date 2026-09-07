defmodule Portal.DirectorySync do
  @moduledoc """
  One writer per directory. A full sync and the webhook jobs of a directory
  never run at the same time: a job snoozes while another job for its
  directory may still be writing. Every job re-reads the provider when it
  runs, so a change that arrived while another job was running is applied by
  a fresh read after that job finished, and no stale response can undo a
  newer one.

  The check is safe because Oban commits a job to `executing` before
  `perform/1` runs. If two nodes fetch two jobs for one directory, each runs
  only if the other was not executing at its own check, and both cannot be
  true. Both may snooze, which the jittered snooze resolves.

  An executing row keeps blocking until its process certainly cannot write:
  Oban kills a job at its timeout, so a row older than that plus a margin is
  dead, and a node that shuts down re-queues the rows of the jobs Oban killed
  on the way out (see `Portal.DirectorySync.Rescuer`). Leaving the cluster
  proves nothing, a disconnected node can still reach the database.
  """
  alias __MODULE__.Database
  require Logger

  @workers %{
    entra: [Portal.Entra.Sync, Portal.Entra.WebhookSync],
    google: [Portal.Google.Sync, Portal.Google.WebhookSync],
    okta: [Portal.Okta.Sync]
  }

  @full_sync_timeout :timer.minutes(100)
  @webhook_timeout :timer.minutes(30)
  @dead_margin :timer.minutes(5)

  def full_sync_timeout, do: @full_sync_timeout
  def webhook_timeout, do: @webhook_timeout

  @doc """
  Runs `fun` unless another job of the provider's workers for the directory
  may still be writing, in which case the job snoozes instead.
  """
  def run_alone(provider, directory_id, job, fun) do
    if running_elsewhere?(provider, directory_id, job) do
      {:snooze, snooze_seconds()}
    else
      fun.()
    end
  end

  @doc """
  Whether another job of the provider's workers for the directory is executing
  and young enough that its process may still be alive.
  """
  def running_elsewhere?(provider, directory_id, %Oban.Job{id: job_id}) do
    workers = workers(provider)
    timeouts = Map.new(workers, &{inspect(&1), &1.timeout(nil)})
    now = DateTime.utc_now()

    Database.executing_jobs(workers, directory_id, job_id)
    |> Enum.any?(fn
      %{attempted_at: nil} ->
        true

      %{worker: worker, attempted_at: attempted_at} ->
        DateTime.diff(now, attempted_at, :millisecond) < timeouts[worker] + @dead_margin
    end)
  end

  @doc """
  Whether any job of the provider's workers for the directory is executing,
  and so may still write an object it fetched before a notification arrived.
  A queued job fetches only once it runs, after the change.
  """
  def busy?(provider, directory_id) do
    Database.executing_jobs?(workers(provider), directory_id)
  end

  def snooze_seconds, do: 15 + :rand.uniform(30)

  @doc """
  Re-queues the sync jobs `node` left executing, or discards the ones with no
  attempts left, the way Oban's Lifeline would later.
  """
  def rescue_orphans(node) do
    Database.rescue_orphans(List.flatten(Map.values(@workers)), node)
  end

  @doc """
  Removes an identity, the memberships its actor holds in the directory's
  groups, and the actor itself when the directory created it and no identity
  names it any more. One transaction, so a retry after a crash cannot find
  the identity gone and leave the memberships behind. The actor is locked
  first, the order a plain actor deletion takes as it cascades, so the two
  cannot deadlock.
  """
  def remove_identity(directory_id, identity) do
    Database.remove_identity(directory_id, identity)
  end

  @doc """
  Deletes what a full sync did not see: the directory's memberships, groups,
  and identities with no sync state at or after `synced_at`, and the actors
  the directory created that no identity names any more.
  """
  def prune(account_id, directory_id, synced_at) do
    {memberships, _} = Database.delete_unsynced_memberships(account_id, directory_id, synced_at)
    {groups, _} = Database.delete_unsynced_groups(account_id, directory_id, synced_at)
    {identities, _} = Database.delete_unsynced_identities(account_id, directory_id, synced_at)
    {actors, _} = Database.delete_actors_without_identities(account_id, directory_id)

    Logger.debug("Pruned what the sync did not see",
      directory_id: directory_id,
      memberships: memberships,
      groups: groups,
      identities: identities,
      actors: actors
    )

    :ok
  end

  @doc """
  Deletes the memberships of one group with no sync state at or after
  `synced_at` and returns how many there were.
  """
  def prune_group_memberships(account_id, directory_id, group_idp_id, synced_at) do
    {deleted, _} =
      Database.delete_unsynced_group_memberships(account_id, directory_id, group_idp_id, synced_at)

    deleted
  end

  @doc """
  Writes the identities a directory read, as `fields` name their attributes,
  creating an actor for each user the account does not know yet and recycling
  the identity rows it already holds. A newer write for the same identity is
  never undone by an older one.
  """
  def upsert_identities(account_id, issuer, directory_id, synced_at, identities, fields) do
    Database.upsert_identities(account_id, issuer, directory_id, synced_at, identities, fields)
  end

  defp workers(provider), do: Map.fetch!(@workers, provider)

  defmodule Database do
    @moduledoc false
    import Ecto.Query
    alias Portal.Safe

    def executing_jobs(workers, directory_id, except_job_id) do
      executing(workers, directory_id)
      |> where([j], j.id != ^except_job_id)
      |> select([j], %{worker: j.worker, attempted_at: j.attempted_at})
      |> Safe.unscoped()
      |> Safe.all()
    end

    def executing_jobs?(workers, directory_id) do
      executing(workers, directory_id)
      |> Safe.unscoped()
      |> Safe.exists?()
    end

    def rescue_orphans(workers, node) do
      orphans =
        from(j in Oban.Job,
          where: j.worker in ^worker_names(workers),
          where: j.state == "executing",
          where: fragment("?[1] = ?", j.attempted_by, ^node)
        )

      {rescued, _} =
        orphans
        |> where([j], j.attempt < j.max_attempts)
        |> Safe.unscoped()
        |> Safe.update_all(set: [state: "available"])

      {discarded, _} =
        orphans
        |> where([j], j.attempt >= j.max_attempts)
        |> Safe.unscoped()
        |> Safe.update_all(set: [state: "discarded", discarded_at: DateTime.utc_now()])

      rescued + discarded
    end

    def remove_identity(directory_id, %{account_id: account_id, id: id, actor_id: actor_id}) do
      Safe.unscoped()
      |> Safe.transaction(fn ->
        lock_actor(account_id, actor_id)
        delete_identity(account_id, id)
        delete_directory_memberships(account_id, directory_id, actor_id)
        delete_actor_without_identities(account_id, directory_id, actor_id)
        {:ok, :removed}
      end)
    end

    def upsert_identities(_account_id, _issuer, _directory_id, _synced_at, [], _fields),
      do: {:ok, %{upserted_identities: 0}}

    def upsert_identities(account_id, issuer, directory_id, synced_at, identities, fields) do
      query = identity_upsert_query(length(identities), fields)

      params =
        identity_upsert_params(account_id, issuer, directory_id, synced_at, identities, fields)

      run_identity_upsert(query, params)
    end

    def delete_unsynced_groups(account_id, directory_id, synced_at) do
      from(g in Portal.Group,
        where: g.account_id == ^account_id,
        where: g.directory_id == ^directory_id,
        where:
          fragment(
            "NOT EXISTS (SELECT 1 FROM group_sync_states gss WHERE gss.group_id = ? AND gss.account_id = ? AND gss.synced_at >= ?)",
            g.id,
            g.account_id,
            ^synced_at
          )
      )
      |> Safe.unscoped()
      |> Safe.delete_all()
    end

    def delete_unsynced_identities(account_id, directory_id, synced_at) do
      from(i in Portal.ExternalIdentity,
        where: i.account_id == ^account_id,
        where: i.directory_id == ^directory_id,
        where:
          fragment(
            "NOT EXISTS (SELECT 1 FROM external_identity_sync_states iss WHERE iss.external_identity_id = ? AND iss.account_id = ? AND iss.synced_at >= ?)",
            i.id,
            i.account_id,
            ^synced_at
          )
      )
      |> Safe.unscoped()
      |> Safe.delete_all()
    end

    def delete_unsynced_memberships(account_id, directory_id, synced_at) do
      unsynced_memberships(account_id, directory_id, synced_at)
      |> Safe.unscoped()
      |> Safe.delete_all()
    end

    def delete_unsynced_group_memberships(account_id, directory_id, group_idp_id, synced_at) do
      unsynced_memberships(account_id, directory_id, synced_at)
      |> where([_m, g], g.idp_id == ^group_idp_id)
      |> Safe.unscoped()
      |> Safe.delete_all()
    end

    def delete_actors_without_identities(account_id, directory_id) do
      from(a in Portal.Actor,
        where: a.account_id == ^account_id,
        where: a.created_by_directory_id == ^directory_id,
        where: fragment("NOT EXISTS (SELECT 1 FROM external_identities WHERE actor_id = ?)", a.id)
      )
      |> Safe.unscoped()
      |> Safe.delete_all()
    end

    # A concurrent OIDC sign-in can insert an identity for the same
    # (account_id, idp_id, issuer) after this statement's snapshot is taken,
    # which the (account_id, id) conflict target does not handle. Re-running
    # picks up the now-committed row via pre_existing_identities and recycles
    # it, so we retry once before surfacing the error.
    defp run_identity_upsert(query, params, retry? \\ true) do
      case Safe.unscoped() |> Safe.query(query, params) do
        {:ok, %Postgrex.Result{rows: rows}} ->
          {:ok, %{upserted_identities: length(rows)}}

        {:error, %Postgrex.Error{postgres: %{code: :unique_violation}}} when retry? ->
          run_identity_upsert(query, params, false)

        {:error, reason} ->
          {:error, reason}
      end
    end

    defp identity_upsert_params(account_id, issuer, directory_id, synced_at, identities, fields) do
      Enum.flat_map(identities, fn identity -> Enum.map(fields, &Map.get(identity, &1)) end) ++
        [Ecto.UUID.dump!(account_id), issuer, Ecto.UUID.dump!(directory_id), synced_at]
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

      data = fields -- [:idp_id]
      keyed = [:idp_id, :issuer, :directory_id | data]

      """
      WITH input_data AS (
        SELECT * FROM (VALUES #{values_clause})
        AS t(#{Enum.join(fields, ", ")})
      ),
      pre_existing_identities AS (
        SELECT ei.id, ei.account_id, ei.actor_id, ei.idp_id
        FROM external_identities ei
        WHERE ei.account_id = $#{account_id}
          AND ei.issuer = $#{issuer}
          AND ei.idp_id IN (SELECT idp_id FROM input_data)
      ),
      existing_actors_by_email AS (
        SELECT DISTINCT ON (id.idp_id) a.id AS actor_id, id.idp_id
        FROM input_data id
        JOIN actors a ON a.email = id.email AND a.account_id = $#{account_id}
        WHERE id.idp_id NOT IN (SELECT idp_id FROM pre_existing_identities)
          AND id.email IS NOT NULL
        ORDER BY id.idp_id, a.inserted_at ASC
      ),
      -- Recycles the actor's existing identity for this directory so a changed
      -- idp_id (issuer unchanged) or a changed issuer (directory reverified
      -- against a new tenant or domain) updates the row in place instead of
      -- inserting a second one and tripping the (account_id, actor_id, issuer)
      -- unique index. Matching on issuer OR directory_id covers both: issuer
      -- alone catches legacy rows whose directory_id is NULL or differs;
      -- directory_id alone catches the row whose issuer just changed. DISTINCT
      -- ON keeps one row per actor, preferring the row that already holds the
      -- new issuer so updating it cannot collide on that index.
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
        FROM input_data id
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
        SELECT atc.new_actor_id AS actor_id, atc.idp_id, #{Enum.map_join(data, ", ", &"id.#{&1}")}
        FROM actors_to_create atc
        JOIN input_data id ON id.idp_id = atc.idp_id
        UNION ALL
        SELECT ei.actor_id, ei.idp_id, #{Enum.map_join(data, ", ", &"id.#{&1}")}
        FROM pre_existing_identities ei
        JOIN input_data id ON id.idp_id = ei.idp_id
        UNION ALL
        SELECT eabe.actor_id, eabe.idp_id, #{Enum.map_join(data, ", ", &"id.#{&1}")}
        FROM existing_actors_by_email eabe
        JOIN input_data id ON id.idp_id = eabe.idp_id
      ),
      upserted_identities AS (
        INSERT INTO external_identities (
          id, actor_id, issuer, idp_id, directory_id, #{Enum.join(data, ", ")},
          account_id, inserted_at, updated_at
        )
        SELECT
          COALESCE(ei.id, edi.id, uuid_generate_v4()),
          aam.actor_id,
          $#{issuer},
          aam.idp_id,
          $#{directory_id},
          #{Enum.map_join(data, ", ", &"aam.#{&1}")},
          $#{account_id},
          $#{synced_at},
          $#{synced_at}
        FROM all_actor_mappings aam
        LEFT JOIN pre_existing_identities ei ON ei.idp_id = aam.idp_id
        LEFT JOIN existing_directory_identities edi ON edi.actor_id = aam.actor_id
        ON CONFLICT (account_id, id)
        DO UPDATE SET
          #{Enum.map_join(keyed, ", ", &"#{&1} = EXCLUDED.#{&1}")},
          updated_at = EXCLUDED.updated_at
        WHERE (#{Enum.map_join(keyed, ", ", &"external_identities.#{&1}")})
              IS DISTINCT FROM
              (#{Enum.map_join(keyed, ", ", &"EXCLUDED.#{&1}")})
          AND NOT EXISTS (
            SELECT 1 FROM external_identity_sync_states iss
            WHERE iss.account_id = external_identities.account_id
              AND iss.external_identity_id = external_identities.id
              AND iss.synced_at >= $#{synced_at}
          )
        RETURNING id, account_id, idp_id
      ),
      all_identity_ids AS (
        SELECT id, account_id FROM upserted_identities
        UNION
        SELECT pei.id, pei.account_id
        FROM pre_existing_identities pei
        WHERE pei.idp_id NOT IN (SELECT idp_id FROM upserted_identities)
      )
      INSERT INTO external_identity_sync_states (external_identity_id, account_id, synced_at)
      SELECT id, account_id, $#{synced_at} FROM all_identity_ids
      ON CONFLICT (account_id, external_identity_id) DO UPDATE SET
        synced_at = EXCLUDED.synced_at
      WHERE external_identity_sync_states.synced_at < EXCLUDED.synced_at
      RETURNING 1
      """
    end

    defp executing(workers, directory_id) do
      from(j in Oban.Job,
        where: j.worker in ^worker_names(workers),
        where: j.state == "executing",
        where: fragment("?->>'directory_id' = ?", j.args, ^directory_id)
      )
    end

    defp worker_names(workers), do: Enum.map(workers, &inspect/1)

    defp unsynced_memberships(account_id, directory_id, synced_at) do
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
    end

    defp lock_actor(account_id, actor_id) do
      from(a in Portal.Actor,
        where: a.account_id == ^account_id,
        where: a.id == ^actor_id,
        lock: "FOR UPDATE"
      )
      |> Safe.unscoped()
      |> Safe.one()
    end

    defp delete_identity(account_id, id) do
      from(i in Portal.ExternalIdentity,
        where: i.account_id == ^account_id,
        where: i.id == ^id
      )
      |> Safe.unscoped()
      |> Safe.delete_all()
    end

    defp delete_directory_memberships(account_id, directory_id, actor_id) do
      from(m in Portal.Membership,
        join: g in Portal.Group,
        on: m.group_id == g.id and m.account_id == g.account_id,
        where: m.account_id == ^account_id,
        where: m.actor_id == ^actor_id,
        where: g.directory_id == ^directory_id
      )
      |> Safe.unscoped()
      |> Safe.delete_all()
    end

    defp delete_actor_without_identities(account_id, directory_id, actor_id) do
      from(a in Portal.Actor,
        where: a.account_id == ^account_id,
        where: a.id == ^actor_id,
        where: a.created_by_directory_id == ^directory_id,
        where: fragment("NOT EXISTS (SELECT 1 FROM external_identities WHERE actor_id = ?)", a.id)
      )
      |> Safe.unscoped()
      |> Safe.delete_all()
    end
  end
end
