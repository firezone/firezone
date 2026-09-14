defmodule Portal.DevicePool.Cache do
  @moduledoc """
  The member bitmaps of device pools, computed on first use and kept current from the
  change stream.

  A pool whose criteria pick the same devices for everyone has one bitmap; an
  own-devices pool has one per actor. The first channel that needs a pool computes it
  here, and every later channel reads the ETS table. A device insert or delete
  recomputes the pools it can belong to, a membership change recomputes the pools of
  its group and a criteria change recomputes the pool. Every change bumps the entry's
  version and is broadcast on this node's account topic with the members that joined
  and left, so a channel that sent the previous version forwards the diff and any
  other channel sends the whole set again.
  """
  use GenServer

  alias __MODULE__.Database
  alias Portal.Cache.Cacheable
  alias Portal.Changes.Change
  alias Portal.DevicePool.Bitmap
  alias Portal.PubSub
  alias Portal.Resource.DeviceMembershipCriteria

  @table :device_pool_bitmaps

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
    scope = DeviceMembershipCriteria.scope(pool.device_membership_criteria, subject)
    key = {subject.account.id, Ecto.UUID.load!(pool.id), scope}

    case :ets.lookup(@table, key) do
      [{^key, %{version: version, members: members}}] -> %{version: version, members: members}
      [] -> GenServer.call(__MODULE__, {:compute, key, pool.device_membership_criteria})
    end
  end

  @doc "Whether a broadcast for `scope` concerns the subject."
  @spec for_subject?(DeviceMembershipCriteria.scope(), Portal.Authentication.Subject.t()) ::
          boolean()
  def for_subject?(:all, _subject), do: true
  def for_subject?({:actor, actor_id}, subject), do: subject.actor.id == actor_id

  @spec subscribe(Ecto.UUID.t()) :: :ok | {:error, term()}
  def subscribe(account_id), do: PubSub.subscribe(topic(account_id))

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
      for {{_account_id, _pool_id, scope} = key, criteria} <- criteria(state, device.account_id),
          holds_device?(criteria, scope, device),
          do: key

    {:noreply, recompute(state, keys)}
  end

  def handle_info(%Change{op: :delete, old_struct: %Portal.Device{type: :client} = device}, state) do
    handle_info(%Change{op: :delete, struct: device}, state)
  end

  def handle_info(%Change{op: op, struct: %Portal.Membership{} = membership}, state)
      when op in [:insert, :delete] do
    keys =
      for {key, criteria} <- criteria(state, membership.account_id),
          DeviceMembershipCriteria.group_id(criteria) == {:ok, membership.group_id},
          do: key

    {:noreply, recompute(state, keys)}
  end

  def handle_info(%Change{op: :delete, old_struct: %Portal.Membership{} = membership}, state) do
    handle_info(%Change{op: :delete, struct: membership}, state)
  end

  def handle_info(
        %Change{op: :update, old_struct: %Portal.Resource{} = old, struct: %Portal.Resource{} = resource},
        state
      ) do
    keys = pool_keys(resource)

    cond do
      keys == [] ->
        {:noreply, state}

      resource.type != :device_pool ->
        {:noreply, forget(state, keys)}

      old.device_membership_criteria != resource.device_membership_criteria ->
        {same_kind, other_kind} =
          Enum.split_with(keys, fn {_account_id, _pool_id, scope} ->
            per_actor?(scope) == DeviceMembershipCriteria.per_actor?(resource.device_membership_criteria)
          end)

        criteria = Map.new(same_kind, &{&1, resource.device_membership_criteria})
        state = forget(state, other_kind)
        {:noreply, recompute(%{state | criteria: Map.merge(state.criteria, criteria)}, same_kind)}

      true ->
        {:noreply, state}
    end
  end

  def handle_info(%Change{op: :delete, old_struct: %Portal.Resource{} = resource}, state) do
    {:noreply, forget(state, pool_keys(resource))}
  end

  def handle_info(%Change{}, state), do: {:noreply, state}

  defp topic(account_id), do: "device_pool_members:#{account_id}"

  defp per_actor?(:all), do: false
  defp per_actor?({:actor, _actor_id}), do: true

  defp holds_device?(_criteria, {:actor, actor_id}, device), do: actor_id == device.actor_id

  defp holds_device?(criteria, :all, device) do
    case DeviceMembershipCriteria.device_ids(criteria) do
      {:ok, device_ids} -> device.id in device_ids
      :error -> true
    end
  end

  defp subscribe_to_changes(state, account_id) do
    if MapSet.member?(state.accounts, account_id) do
      state
    else
      :ok = PubSub.Changes.subscribe(account_id, :devices)
      :ok = PubSub.Changes.subscribe(account_id, :memberships)
      :ok = PubSub.Changes.subscribe(account_id, :resources)
      %{state | accounts: MapSet.put(state.accounts, account_id)}
    end
  end

  defp criteria(state, account_id) do
    for {{^account_id, _pool_id, _scope}, _criteria} = entry <- state.criteria, do: entry
  end

  defp pool_keys(%Portal.Resource{account_id: account_id, id: pool_id}) do
    for {key, _entry} <- :ets.match_object(@table, {{account_id, pool_id, :_}, :_}), do: key
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
      |> DeviceMembershipCriteria.where_members(criteria, scope)
      |> select([devices: d], %{ipv4: d.ipv4, ipv6: d.ipv6})
      |> Safe.unscoped()
      |> Safe.all()
    end
  end
end
