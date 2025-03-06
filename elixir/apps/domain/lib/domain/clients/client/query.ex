defmodule Domain.Clients.Client.Query do
  use Domain, :query

  def all do
    from(clients in Domain.Clients.Client, as: :clients)
  end

  def not_deleted do
    all()
    |> where([clients: clients], is_nil(clients.deleted_at))
  end

  def by_id(queryable, id) do
    where(queryable, [clients: clients], clients.id == ^id)
  end

  def by_actor_id(queryable, actor_id) do
    where(queryable, [clients: clients], clients.actor_id == ^actor_id)
  end

  def only_for_active_actors(queryable) do
    queryable
    |> with_joined_actor()
    |> where([actor: actor], is_nil(actor.disabled_at))
  end

  def by_actor_type(queryable, {:in, types}) do
    queryable
    |> with_joined_actor()
    |> where([actor: actor], actor.type in ^types)
  end

  def by_account_id(queryable, account_id) do
    where(queryable, [clients: clients], clients.account_id == ^account_id)
  end

  def by_last_used_token_id(queryable, last_used_token_id) do
    where(queryable, [clients: clients], clients.last_used_token_id == ^last_used_token_id)
  end

  def by_last_seen_within(queryable, period, unit) do
    where(queryable, [clients: clients], clients.last_seen_at > ago(^period, ^unit))
  end

  def select_distinct_actor_id(queryable) do
    queryable
    |> select([clients: clients], clients.actor_id)
    |> distinct(true)
  end

  def count_clients_by_actor_id(queryable \\ not_deleted()) do
    queryable
    |> group_by([clients: clients], clients.actor_id)
    |> select([clients: clients], %{
      actor_id: clients.actor_id,
      count: count(clients.id)
    })
  end

  def returning_not_deleted(queryable) do
    select(queryable, [clients: clients], clients)
  end

  def delete(queryable) do
    queryable
    |> Ecto.Query.select([clients: clients], clients)
    |> Ecto.Query.update([clients: clients],
      set: [
        deleted_at: fragment("COALESCE(?, timezone('UTC', NOW()))", clients.deleted_at)
      ]
    )
  end

  def with_joined_actor(queryable) do
    with_named_binding(queryable, :actor, fn queryable, binding ->
      join(
        queryable,
        :inner,
        [clients: clients],
        actor in ^Domain.Actors.Actor.Query.not_deleted(),
        on: clients.actor_id == actor.id,
        as: ^binding
      )
    end)
  end

  def with_preloaded_actor(queryable) do
    queryable
    |> with_joined_actor()
    |> preload([clients: clients, actor: actor], actor: actor)
  end

  def with_preloaded_identity(queryable) do
    with_named_binding(queryable, :identity, fn queryable, binding ->
      queryable
      |> join(:inner, [clients: clients], identity in assoc(clients, ^binding), as: ^binding)
      |> preload([clients: clients, identity: identity], identity: identity)
    end)
  end

  # Pagination

  @impl Domain.Repo.Query
  def cursor_fields,
    do: [
      {:clients, :desc, :last_seen_at},
      {:clients, :desc, :id}
    ]

  @impl Domain.Repo.Query
  def preloads,
    do: [
      online?: &Domain.Clients.preload_clients_presence/1
    ]

  @impl Domain.Repo.Query
  def filters,
    do: [
      %Domain.Repo.Filter{
        name: :name,
        title: "Name",
        type: {:string, :websearch},
        fun: &filter_by_name_fts/2
      },
      %Domain.Repo.Filter{
        name: :verification,
        title: "Verification Status",
        type: :string,
        values: [
          {"Verified", "verified"},
          {"Not Verified", "not_verified"}
        ],
        fun: &filter_by_verification/2
      },
      %Domain.Repo.Filter{
        name: :presence,
        title: "Presence",
        type: :string,
        values: [
          {"Online", "online"},
          {"Offline", "offline"}
        ],
        fun: &filter_by_presence/2
      },
      %Domain.Repo.Filter{
        name: :client_or_actor_name,
        title: "Client Name or Actor Name",
        type: {:string, :websearch},
        fun: &filter_by_client_or_actor_name/2
      }
    ]

  def filter_by_name_fts(queryable, name) do
    {queryable, dynamic([clients: clients], fulltext_search(clients.name, ^name))}
  end

  def filter_by_verification(queryable, "verified") do
    {queryable, dynamic([clients: clients], not is_nil(clients.verified_at))}
  end

  def filter_by_verification(queryable, "not_verified") do
    {queryable, dynamic([clients: clients], is_nil(clients.verified_at))}
  end

  def filter_by_presence(queryable, "online") do
    ids =
      queryable
      |> fetch_queried_account_id()
      |> Domain.Clients.online_client_ids()

    {queryable, dynamic([clients: clients], clients.id in ^ids)}
  end

  def filter_by_presence(queryable, "offline") do
    ids =
      queryable
      |> fetch_queried_account_id()
      |> Domain.Clients.online_client_ids()

    {queryable, dynamic([clients: clients], clients.id not in ^ids)}
  end

  # there is no easy way to pass additional data to our filters right now so we
  # extract the account_id from the queryable instead
  defp fetch_queried_account_id(queryable) do
    Enum.find_value(queryable.wheres, fn
      %Ecto.Query.BooleanExpr{
        op: :and,
        expr: {:==, _, [{{_, _, [_, :account_id]}, _, _}, {:^, _, [b_idx]}]},
        params: [{account_id, {b_idx, :account_id}}]
      } ->
        account_id

      _ ->
        nil
    end)
  end

  def filter_by_client_or_actor_name(queryable, name) do
    queryable =
      with_named_binding(queryable, :actor, fn queryable, binding ->
        join(queryable, :inner, [clients: clients], actor in assoc(clients, ^binding),
          as: ^binding
        )
      end)

    {queryable,
     dynamic(
       [clients: clients, actor: actor],
       fulltext_search(clients.name, ^name) or fulltext_search(actor.name, ^name)
     )}
  end
end
