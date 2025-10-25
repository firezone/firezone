defmodule Domain.Auth.Identity.Query do
  use Domain, :query
  alias Domain.Repo

  def all do
    from(identities in Domain.Auth.Identity, as: :identities)
  end

  def not_disabled(queryable \\ all()) do
    queryable
    |> with_assoc(:inner, :actor)
    |> where([actor: actor], is_nil(actor.disabled_at))
    # Don't join providers; instead allow identities with no provider, or where an enabled provider exists.
    |> where(
      [identities: identities],
      is_nil(identities.provider_id) or
        exists(
          from provider in Domain.Auth.Provider,
            where:
              provider.id == parent_as(:identities).provider_id and
                is_nil(provider.disabled_at),
            select: 1
        )
    )
  end

  def by_id(queryable, id)

  def by_id(queryable, {:not, id}) do
    where(queryable, [identities: identities], identities.id != ^id)
  end

  def by_id(queryable, id) do
    where(queryable, [identities: identities], identities.id == ^id)
  end

  def by_account_id(queryable, account_id) do
    where(queryable, [identities: identities], identities.account_id == ^account_id)
  end

  def by_actor_id(queryable, {:in, actor_ids}) do
    where(queryable, [identities: identities], identities.actor_id in ^actor_ids)
  end

  def by_actor_id(queryable, actor_id) do
    where(queryable, [identities: identities], identities.actor_id == ^actor_id)
  end

  def by_provider_id(queryable, provider_id) do
    queryable
    |> where([identities: identities], identities.provider_id == ^provider_id)
  end

  def by_issuer(queryable, issuer) do
    where(queryable, [identities: identities], identities.issuer == ^issuer)
  end

  def by_idp_id(queryable, idp_id) do
    where(queryable, [identities: identities], identities.idp_id == ^idp_id)
  end

  def by_adapter(queryable, adapter) do
    where(queryable, [identities: identities], identities.adapter == ^adapter)
  end

  def by_provider_identifier(queryable, provider_identifier)

  def by_provider_identifier(queryable, {:in, provider_identifiers}) do
    where(
      queryable,
      [identities: identities],
      identities.provider_identifier in ^provider_identifiers
    )
  end

  def by_provider_identifier(queryable, provider_identifier) do
    where(
      queryable,
      [identities: identities],
      identities.provider_identifier == ^provider_identifier
    )
  end

  def by_provider_claims(queryable, provider_identifier, nil) do
    by_provider_identifier(queryable, provider_identifier)
  end

  def by_provider_claims(queryable, provider_identifier, "") do
    by_provider_identifier(queryable, provider_identifier)
  end

  def by_provider_claims(queryable, provider_identifier, email) do
    # For manually created IdP identities (where last_seen_at is nil)
    # we also try to fetch them by email, so that users can provision
    # them without knowing which ID will be assigned to the OIDC sub claim.
    where(
      queryable,
      [identities: identities],
      identities.provider_identifier == ^provider_identifier or
        (is_nil(identities.last_seen_at) and identities.provider_identifier == ^email)
    )
    |> order_by([identities: identities],
      desc: identities.provider_identifier == ^provider_identifier,
      desc_nulls_last: identities.last_seen_at
    )
    |> limit(1)
  end

  def by_id_or_provider_identifier(queryable, id_or_provider_identifier) do
    if Domain.Repo.valid_uuid?(id_or_provider_identifier) do
      where(
        queryable,
        [identities: identities],
        identities.provider_identifier == ^id_or_provider_identifier or
          identities.id == ^id_or_provider_identifier
      )
    else
      by_provider_identifier(queryable, id_or_provider_identifier)
    end
  end

  def lock(queryable) do
    lock(queryable, "FOR UPDATE")
  end

  def returning_ids(queryable) do
    select(queryable, [identities: identities], identities.id)
  end

  def returning_actor_ids(queryable) do
    select(queryable, [identities: identities], identities.actor_id)
  end

  def returning_distinct_actor_ids(queryable) do
    queryable
    |> select([identities: identities], identities.actor_id)
    |> distinct(true)
  end

  def group_by_provider_id(queryable) do
    queryable
    |> group_by([identities: identities], identities.provider_id)
    |> select([identities: identities], %{
      provider_id: identities.provider_id,
      count: count(identities.id)
    })
  end

  def max_last_seen_at_grouped_by_actor_id(queryable) do
    queryable
    |> group_by([identities: identities], identities.actor_id)
    |> select([identities: identities], %{
      actor_id: identities.actor_id,
      max: max(identities.last_seen_at)
    })
  end

  def with_preloaded_assoc(queryable, type \\ :left, assoc) do
    queryable
    |> with_assoc(type, assoc)
    |> preload([{^assoc, assoc}], [{^assoc, assoc}])
  end

  def with_assoc(queryable, type \\ :left, assoc) do
    with_named_binding(queryable, assoc, fn query, binding ->
      join(query, type, [identities: identities], a in assoc(identities, ^binding), as: ^binding)
    end)
  end

  def batch_upsert(_account_id, _provider_id, _now, []), do: {:ok, %{upserted_identities: 0}}

  def batch_upsert(account_id, provider_id, now, identity_attrs) do
    query = build_upsert_query(length(identity_attrs))
    params = build_upsert_params(account_id, provider_id, now, identity_attrs)

    case Repo.query(query, params) do
      {:ok, %Postgrex.Result{rows: rows}} -> {:ok, %{upserted_identities: length(rows)}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp build_upsert_query(count) do
    values_clause =
      for i <- 1..count, base = (i - 1) * 3 do
        "($#{base + 1}, $#{base + 2}, $#{base + 3})"
      end
      |> Enum.join(", ")

    offset = count * 3
    account_id = offset + 1
    provider_id = offset + 2
    now = offset + 3

    """
    WITH input_data AS (
      SELECT * FROM (VALUES #{values_clause})
      AS t(provider_identifier, email, name)
    ),
    existing_identities AS (
      SELECT ai.id, ai.actor_id, ai.provider_identifier
      FROM auth_identities ai
      WHERE ai.account_id = $#{account_id}
        AND ai.provider_id = $#{provider_id}
        AND ai.provider_identifier IN (SELECT provider_identifier FROM input_data)
    ),
    actors_to_create AS (
      SELECT
        uuid_generate_v4() AS new_actor_id,
        id.provider_identifier,
        id.name
      FROM input_data id
      WHERE id.provider_identifier NOT IN (
        SELECT provider_identifier FROM existing_identities
      )
    ),
    new_actors AS (
      INSERT INTO actors (id, type, account_id, name, last_synced_at, inserted_at, updated_at)
      SELECT
        new_actor_id,
        'account_user',
        $#{account_id},
        name,
        $#{now},
        $#{now},
        $#{now}
      FROM actors_to_create
      RETURNING id, name
    ),
    updated_actors AS (
      UPDATE actors
      SET name = id.name, last_synced_at = $#{now}, updated_at = $#{now}
      FROM input_data id
      JOIN existing_identities ei ON ei.provider_identifier = id.provider_identifier
      WHERE actors.id = ei.actor_id
      RETURNING actors.id
    ),
    all_actor_mappings AS (
      SELECT atc.new_actor_id AS actor_id, atc.provider_identifier, id.email
      FROM actors_to_create atc
      JOIN input_data id ON id.provider_identifier = atc.provider_identifier
      UNION ALL
      SELECT ei.actor_id, ei.provider_identifier, id.email
      FROM existing_identities ei
      JOIN input_data id ON id.provider_identifier = ei.provider_identifier
    )
    INSERT INTO auth_identities (
      id, actor_id, provider_id, provider_identifier, provider_state,
      account_id, email, created_by, inserted_at, created_by_subject
    )
    SELECT
      COALESCE(ei.id, uuid_generate_v4()),
      aam.actor_id,
      $#{provider_id},
      aam.provider_identifier,
      jsonb_build_object('userinfo', jsonb_build_object('email', aam.email)),
      $#{account_id},
      aam.email,
      'provider',
      $#{now},
      jsonb_build_object('name', 'Provider', 'email', null)
    FROM all_actor_mappings aam
    LEFT JOIN existing_identities ei ON ei.provider_identifier = aam.provider_identifier
    ON CONFLICT (account_id, provider_id, provider_identifier)
    DO UPDATE SET
      email = EXCLUDED.email,
      provider_state = COALESCE(auth_identities.provider_state, '{}'::jsonb) ||
                      jsonb_build_object('userinfo',
                        COALESCE(auth_identities.provider_state->'userinfo', '{}'::jsonb) ||
                        jsonb_build_object('email', EXCLUDED.email)
                      )
    RETURNING 1
    """
  end

  defp build_upsert_params(account_id, provider_id, now, attrs) do
    params =
      Enum.flat_map(attrs, fn a ->
        [a.provider_identifier, a.email, a.name]
      end)

    params ++ [Ecto.UUID.dump!(account_id), Ecto.UUID.dump!(provider_id), now]
  end

  def upsert_by_idp_fields(account_id, email, email_verified, issuer, idp_id, profile_attrs) do
    profile_fields =
      ~w[name given_name family_name middle_name nickname preferred_username profile picture]

    profile_values = Enum.map(profile_fields, &Map.get(profile_attrs, &1))
    update_set = Enum.map_join(profile_fields, ", ", &"#{&1} = EXCLUDED.#{&1}")
    insert_fields = Enum.join(profile_fields, ", ")
    value_placeholders = Enum.map_join(6..(5 + length(profile_fields)), ", ", &"$#{&1}")

    query = """
    WITH actor_lookup AS (
      SELECT id FROM actors
      WHERE account_id = $1 AND email = $2 AND disabled_at IS NULL AND $3 = true
      LIMIT 1
    ),
    existing_identity AS (
      SELECT actor_id FROM auth_identities
      WHERE account_id = $1 AND issuer = $4 AND idp_id = $5
      LIMIT 1
    )
    INSERT INTO auth_identities (
      id, account_id, issuer, idp_id, actor_id,
      #{insert_fields},
      inserted_at, created_by, created_by_subject
    )
    SELECT uuid_generate_v4(), $1, $4, $5,
           COALESCE(actor_lookup.id, existing_identity.actor_id),
           #{value_placeholders}, $14, $15,
           jsonb_build_object('name', 'System', 'email', null)
    FROM (SELECT 1) AS dummy
    LEFT JOIN actor_lookup ON true
    LEFT JOIN existing_identity ON true
    WHERE actor_lookup.id IS NOT NULL OR existing_identity.actor_id IS NOT NULL
    ON CONFLICT (account_id, issuer, idp_id) WHERE issuer IS NOT NULL OR idp_id IS NOT NULL
    DO UPDATE SET #{update_set}
    RETURNING *
    """

    params =
      [Ecto.UUID.dump!(account_id), email, email_verified, issuer, idp_id] ++
        profile_values ++ [DateTime.utc_now(), "system"]

    case Repo.query(query, params) do
      {:ok, %{rows: [row], columns: cols}} ->
        identity = Repo.load(Domain.Auth.Identity, {cols, row})
        {:ok, Repo.preload(identity, [:actor, :account])}

      {:ok, %{rows: []}} ->
        {:error, :actor_not_found}

      {:error, _} = error ->
        error
    end
  end

  # Pagination

  @impl Domain.Repo.Query
  def cursor_fields,
    do: [
      {:identities, :asc, :inserted_at},
      {:identities, :asc, :id}
    ]
end
