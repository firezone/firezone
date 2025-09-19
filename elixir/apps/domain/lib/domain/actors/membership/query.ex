defmodule Domain.Actors.Membership.Query do
  use Domain, :query
  alias Domain.Repo
  alias Domain.Actors.{Actor, Group, Membership}

  def all do
    from(memberships in Membership, as: :memberships)
  end

  def only_editable_groups(queryable \\ all()) do
    queryable
    |> with_joined_groups()
    |> where([groups: groups], is_nil(groups.provider_id) and groups.type == :static)
  end

  def by_actor_id(queryable \\ all(), actor_id) do
    where(queryable, [memberships: memberships], memberships.actor_id == ^actor_id)
  end

  def by_group_id(queryable \\ all(), group_id)

  def by_group_id(queryable, {:in, group_ids}) do
    where(queryable, [memberships: memberships], memberships.group_id in ^group_ids)
  end

  def by_group_id(queryable, group_id) do
    where(queryable, [memberships: memberships], memberships.group_id == ^group_id)
  end

  def by_group_id_and_actor_id(queryable \\ all(), {:in, tuples}) do
    queryable = where(queryable, [], false)

    Enum.reduce(tuples, queryable, fn {group_id, actor_id}, queryable ->
      or_where(
        queryable,
        [memberships: memberships],
        memberships.group_id == ^group_id and memberships.actor_id == ^actor_id
      )
    end)
  end

  def by_account_id(queryable \\ all(), account_id) do
    where(queryable, [memberships: memberships], memberships.account_id == ^account_id)
  end

  def by_group_provider_id(queryable \\ all(), provider_id) do
    queryable
    |> with_joined_groups()
    |> where([groups: groups], groups.provider_id == ^provider_id)
  end

  def not_synced_at(queryable, synced_at) do
    where(queryable, [memberships: memberships], memberships.last_synced_at != ^synced_at)
  end

  def count_actors_by_group_id(queryable \\ all()) do
    queryable
    |> group_by([memberships: memberships], memberships.group_id)
    |> with_joined_actors()
    |> select([memberships: memberships, actors: actors], %{
      group_id: memberships.group_id,
      count: count(actors.id)
    })
  end

  def count_groups_by_actor_id(queryable \\ all()) do
    queryable
    |> group_by([memberships: memberships], memberships.actor_id)
    |> with_joined_groups()
    |> select([memberships: memberships, groups: groups], %{
      actor_id: memberships.actor_id,
      count: count(groups.id)
    })
  end

  def select_distinct_group_ids(queryable \\ all()) do
    queryable
    |> select([memberships: memberships], memberships.group_id)
    |> distinct(true)
  end

  def returning_all(queryable \\ all()) do
    select(queryable, [memberships: memberships], memberships)
  end

  def with_joined_actors(queryable \\ all()) do
    join(queryable, :inner, [memberships: memberships], actors in ^Actor.Query.not_deleted(),
      on: actors.id == memberships.actor_id,
      as: :actors
    )
  end

  def with_joined_groups(queryable \\ all()) do
    join(queryable, :inner, [memberships: memberships], groups in ^Group.Query.not_deleted(),
      on: groups.id == memberships.group_id,
      as: :groups
    )
  end

  def lock(queryable \\ all()) do
    lock(queryable, "FOR UPDATE")
  end

  def batch_upsert(_account_id, _provider_id, _now, []), do: {:ok, %{upserted_memberships: 0}}

  def batch_upsert(account_id, provider_id, now, tuples) do
    query = build_upsert_query(length(tuples))
    params = build_upsert_params(account_id, provider_id, now, tuples)

    case Repo.query(query, params) do
      {:ok, %Postgrex.Result{num_rows: num_rows}} -> {:ok, %{upserted_memberships: num_rows}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp build_upsert_query(count) do
    values_clause =
      for i <- 1..count, base = (i - 1) * 2 do
        "($#{base + 1}, $#{base + 2})"
      end
      |> Enum.join(", ")

    offset = count * 2
    account_id = offset + 1
    provider_id = offset + 2
    now = offset + 3

    """
    WITH membership_input AS (
      SELECT * FROM (VALUES #{values_clause})
      AS t(group_provider_identifier, user_provider_identifier)
    ),
    resolved_memberships AS (
      SELECT
        ai.actor_id,
        ag.id as group_id
      FROM membership_input mi
      JOIN auth_identities ai ON (
        ai.provider_identifier = mi.user_provider_identifier
        AND ai.account_id = $#{account_id}
        AND ai.provider_id = $#{provider_id}
        AND ai.deleted_at IS NULL
      )
      JOIN actor_groups ag ON (
        ag.provider_identifier = mi.group_provider_identifier
        AND ag.account_id = $#{account_id}
        AND ag.provider_id = $#{provider_id}
        AND ag.deleted_at IS NULL
      )
    )
    INSERT INTO actor_group_memberships (id, actor_id, group_id, account_id, last_synced_at)
    SELECT
      uuid_generate_v4(),
      rm.actor_id,
      rm.group_id,
      $#{account_id} AS account_id,
      $#{now} AS last_synced_at
    FROM resolved_memberships rm
    ON CONFLICT (actor_id, group_id) DO UPDATE SET
      last_synced_at = EXCLUDED.last_synced_at
    RETURNING 1
    """
  end

  defp build_upsert_params(account_id, provider_id, now, tuples) do
    params =
      Enum.flat_map(tuples, fn {group_provider_identifier, user_provider_identifier} ->
        [group_provider_identifier, user_provider_identifier]
      end)

    params ++ [Ecto.UUID.dump!(account_id), Ecto.UUID.dump!(provider_id), now]
  end

  # Pagination

  @impl Domain.Repo.Query
  def cursor_fields,
    do: [
      {:memberships, :asc, :inserted_at},
      {:memberships, :asc, :id}
    ]
end
