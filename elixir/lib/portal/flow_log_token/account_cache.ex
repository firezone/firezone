defmodule Portal.FlowLogToken.AccountCache do
  @moduledoc """
  Remembers the account each flow-log token names, so verifying an upload does
  not read the database.

  An account stays cached until a change to it arrives. An id with no account
  stays cached until an account with that id is inserted (for example by a
  region transfer). Anyone can mint a token naming any id, so ids with no
  account stop being cached once the cache is full.
  """
  use GenServer

  alias Portal.{Account, Changes.Change, PubSub}

  @table __MODULE__

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Returns the cached account for `account_id`, or calls `load` and caches the
  result. `nil` means no account has this id.
  """
  @spec fetch(Ecto.UUID.t(), (-> Account.t() | nil)) :: Account.t() | nil
  def fetch(account_id, load) do
    case :ets.lookup(@table, account_id) do
      [{^account_id, account}] -> account
      [] -> load_and_cache(account_id, load)
    end
  end

  @doc "Drops the cached entry for `account_id`."
  @spec evict(Ecto.UUID.t()) :: true
  def evict(account_id), do: :ets.delete(@table, account_id)

  defp load_and_cache(account_id, load) do
    case load.() do
      nil ->
        if :ets.info(@table, :size) < max_entries(), do: :ets.insert(@table, {account_id, nil})
        nil

      %Account{} ->
        # Watch before the load we cache, so no change can land between them.
        :ok = GenServer.call(__MODULE__, {:watch, account_id})
        account = load.()
        :ets.insert(@table, {account_id, account})
        account
    end
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    # Account inserts only arrive on the all-accounts topic.
    :ok = PubSub.Changes.subscribe_to_accounts()
    {:ok, MapSet.new()}
  end

  @impl true
  def handle_call({:watch, account_id}, _from, watched) do
    if MapSet.member?(watched, account_id) do
      {:reply, :ok, watched}
    else
      :ok = PubSub.Changes.subscribe(account_id, :accounts)
      {:reply, :ok, MapSet.put(watched, account_id)}
    end
  end

  @impl true
  def handle_info(%Change{struct: %Account{id: id}}, watched) do
    evict(id)
    {:noreply, watched}
  end

  def handle_info(%Change{old_struct: %Account{id: id}}, watched) do
    evict(id)
    {:noreply, watched}
  end

  def handle_info(_message, watched), do: {:noreply, watched}

  defp max_entries do
    Portal.Config.get_env(:portal, __MODULE__, []) |> Keyword.fetch!(:max_entries)
  end
end
