defmodule Portal.SlugRegistry.Cache do
  @moduledoc """
  Remembers recent registry lookups for slugs this portal does not know, so a
  scanner or a user who keeps refreshing a bad URL does not turn into a stream
  of registry reads. Hits live a few minutes, misses and failures one minute.
  A sweep drops expired entries every minute, and a full cache stops taking
  new entries until the sweep makes room.
  """
  use GenServer

  @table __MODULE__
  @hit_ttl :timer.minutes(5)
  @miss_ttl :timer.minutes(1)
  @sweep_interval :timer.minutes(1)

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @spec lookup(String.t()) :: {:ok, Portal.SlugRegistry.entry()} | :not_found | {:error, :unavailable}
  def lookup(slug) do
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@table, slug) do
      [{^slug, result, expires_at}] when expires_at > now ->
        result

      _ ->
        result = Portal.SlugRegistry.lookup(slug)
        ttl = if match?({:ok, _}, result), do: @hit_ttl, else: @miss_ttl
        maybe_insert(slug, result, now + ttl)
        result
    end
  end

  @doc false
  def clear, do: :ets.delete_all_objects(@table)

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    schedule_sweep()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    now = System.monotonic_time(:millisecond)
    :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:"=<", :"$1", now}], [true]}])
    schedule_sweep()
    {:noreply, state}
  end

  defp maybe_insert(slug, result, expires_at) do
    if :ets.info(@table, :size) < max_entries() do
      :ets.insert(@table, {slug, result, expires_at})
    end
  end

  defp max_entries do
    Portal.Config.get_env(:portal, __MODULE__, []) |> Keyword.fetch!(:max_entries)
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval)
end
