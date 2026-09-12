defmodule Portal.DevicePool.Cache do
  @moduledoc """
  The member bitmaps of device pools, computed on first use and kept current from the
  change stream.

  A listed pool has one bitmap for everyone; an own-devices pool has one per actor. The
  first channel that needs a pool computes it here, and every later channel reads the
  ETS table. A device insert or delete recomputes the own-devices bitmaps of its actor
  and a criteria change recomputes the pool. Every change bumps the entry's version and
  is broadcast on this node's account topic with the members that joined and left, so a
  channel that sent the previous version forwards the diff and any other channel sends
  the whole set again.
  """
  use GenServer

  alias __MODULE__.Database
  alias Portal.Cache.Cacheable
  alias Portal.Changes.Change
  alias Portal.DevicePool.Bitmap
  alias Portal.PubSub
  alias Portal.Resource.DeviceMembershipCriteria

  @table :device_pool_bitmaps

  @type scope :: :all | {:actor, Ecto.UUID.t()}

  @typedoc "What a channel holds for a pool: the version it last sent and the wire form."
  @type entry :: %{version: pos_integer(), members: Bitmap.t()}

  @typedoc "A change to a pool's members, from `previous` to `version`."
  @type update :: %{
          version: pos_integer(),
          previous: pos_integer(),
          members: Bitmap.t(),
          added: Bitmap.t(),
          removed: Bitmap.t()
        }

  @doc "Starts the cache; `:callers` are copied into `$callers` for the database sandbox."
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "The member bitmaps of the pool for the subject and their version, computed on first use."
  @spec members(Cacheable.Resource.t(), Portal.Authentication.Subject.t()) :: entry()
  def members(%Cacheable.Resource{type: :device_pool} = pool, subject) do
    key = {subject.account.id, Ecto.UUID.load!(pool.id), scope(pool.device_membership_criteria, subject)}

    case :ets.lookup(@table, key) do
      [{^key, %{version: version, members: members}}] -> %{version: version, members: members}
      [] -> GenServer.call(__MODULE__, {:compute, key, pool.device_membership_criteria})
    end
  end

  @doc "Whether a broadcast for `scope` concerns the subject."
  @spec for_subject?(scope(), Portal.Authentication.Subject.t()) :: boolean()
  def for_subject?(:all, _subject), do: true
  def for_subject?({:actor, actor_id}, subject), do: subject.actor.id == actor_id

  @spec subscribe(Ecto.UUID.t()) :: :ok | {:error, term()}
  def subscribe(account_id), do: PubSub.subscribe(topic(account_id))

  defp topic(account_id), do: "device_pool_members:#{account_id}"

  defp scope(%DeviceMembershipCriteria{} = criteria, subject) do
    case kind(criteria) do
      :all -> :all
      :actor -> {:actor, subject.actor.id}
    end
  end

  defp kind(%DeviceMembershipCriteria{} = criteria) do
    case DeviceMembershipCriteria.device_ids(criteria) do
      {:ok, _device_ids} -> :all
      :error -> :actor
    end
  end

  defp kind(:all), do: :all
  defp kind({:actor, _actor_id}), do: :actor

  @impl true
  def init(opts) do
    Process.put(:"$callers", Keyword.get(opts, :callers, []))
    :ets.new(@table, [:named_table, :protected, :set, read_concurrency: true])
    {:ok, %{accounts: MapSet.new(), criteria: %{}}}
  end

  @impl true
  def handle_call({:compute, {account_id, _pool_id, _scope} = key, criteria}, _from, state) do
    state = subscribe_to_changes(state, account_id)

    entry =
      case :ets.lookup(@table, key) do
        [{^key, entry}] ->
          entry

        [] ->
          sets = compute(key, criteria)
          entry = %{version: 1, sets: sets, members: Bitmap.wire(sets)}
          :ets.insert(@table, {key, entry})
          entry
      end

    {:reply, Map.take(entry, [:version, :members]),
     %{state | criteria: Map.put(state.criteria, key, criteria)}}
  end

  @impl true
  def handle_info(%Change{op: op, struct: %Portal.Device{type: :client} = device}, state)
      when op in [:insert, :delete] do
    keys =
      for {{account_id, _pool_id, {:actor, actor_id}} = key, _members} <- entries(device.account_id),
          account_id == device.account_id and actor_id == device.actor_id,
          do: key

    {:noreply, recompute(state, keys)}
  end

  def handle_info(%Change{op: :delete, old_struct: %Portal.Device{type: :client} = device}, state) do
    handle_info(%Change{op: :delete, struct: device}, state)
  end

  def handle_info(
        %Change{op: :update, old_struct: %Portal.Resource{} = old, struct: %Portal.Resource{} = resource},
        state
      ) do
    keys = for {{_account_id, pool_id, _scope} = key, _} <- entries(resource.account_id), pool_id == resource.id, do: key

    cond do
      keys == [] ->
        {:noreply, state}

      resource.type != :device_pool ->
        {:noreply, forget(state, keys)}

      old.device_membership_criteria != resource.device_membership_criteria ->
        {same_kind, other_kind} =
          Enum.split_with(keys, fn {_account_id, _pool_id, scope} ->
            kind(scope) == kind(resource.device_membership_criteria)
          end)

        criteria = Map.new(same_kind, &{&1, resource.device_membership_criteria})
        state = forget(state, other_kind)
        {:noreply, recompute(%{state | criteria: Map.merge(state.criteria, criteria)}, same_kind)}

      true ->
        {:noreply, state}
    end
  end

  def handle_info(%Change{op: :delete, old_struct: %Portal.Resource{} = resource}, state) do
    keys = for {{_account_id, pool_id, _scope} = key, _} <- entries(resource.account_id), pool_id == resource.id, do: key
    {:noreply, forget(state, keys)}
  end

  def handle_info(%Change{}, state), do: {:noreply, state}

  defp subscribe_to_changes(state, account_id) do
    if MapSet.member?(state.accounts, account_id) do
      state
    else
      :ok = PubSub.Changes.subscribe(account_id, :devices)
      :ok = PubSub.Changes.subscribe(account_id, :resources)
      %{state | accounts: MapSet.put(state.accounts, account_id)}
    end
  end

  defp entries(account_id) do
    :ets.match_object(@table, {{account_id, :_, :_}, :_})
  end

  defp recompute(state, keys) do
    for {account_id, pool_id, scope} = key <- keys,
        [{^key, %{version: version, sets: old_sets}}] = :ets.lookup(@table, key),
        sets = compute(key, Map.fetch!(state.criteria, key)),
        sets != old_sets do
      members = Bitmap.wire(sets)
      {added, removed} = Bitmap.diff(old_sets, sets)
      :ets.insert(@table, {key, %{version: version + 1, sets: sets, members: members}})

      PubSub.local_broadcast(
        topic(account_id),
        {:device_pool_members_updated, pool_id, scope,
         %{
           version: version + 1,
           previous: version,
           members: members,
           added: Bitmap.wire(added),
           removed: Bitmap.wire(removed)
         }}
      )
    end

    state
  end

  defp forget(state, keys) do
    Enum.each(keys, &:ets.delete(@table, &1))
    %{state | criteria: Map.drop(state.criteria, keys)}
  end

  defp compute({account_id, _pool_id, scope}, criteria) do
    account_id
    |> Database.member_addresses(scope, criteria)
    |> Bitmap.sets()
  end

  defmodule Database do
    import Ecto.Query

    alias Portal.Resource.DeviceMembershipCriteria
    alias Portal.Safe

    def member_addresses(account_id, scope, criteria) do
      from(d in Portal.Device, as: :devices)
      |> where([devices: d], d.account_id == ^account_id and d.type == :client)
      |> where_members(scope, criteria)
      |> select([devices: d], %{ipv4: d.ipv4, ipv6: d.ipv6})
      |> Safe.unscoped()
      |> Safe.all()
    end

    defp where_members(query, :all, criteria) do
      {:ok, device_ids} = DeviceMembershipCriteria.device_ids(criteria)
      where(query, [devices: d], d.id in ^device_ids)
    end

    defp where_members(query, {:actor, actor_id}, _criteria) do
      where(query, [devices: d], d.actor_id == ^actor_id)
    end
  end
end
