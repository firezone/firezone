defmodule Portal.SlugRegistry.Cache do
  @moduledoc """
  Remembers recent registry lookups for slugs this portal does not know, so a
  scanner or a user who keeps refreshing a bad URL does not turn into a stream
  of registry reads. Hits live a few minutes, misses and failures one minute.
  """
  use GenServer

  @table __MODULE__
  @hit_ttl :timer.minutes(5)
  @miss_ttl :timer.minutes(1)

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
        :ets.insert(@table, {slug, result, now + ttl})
        result
    end
  end

  @doc false
  def clear, do: :ets.delete_all_objects(@table)

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    {:ok, %{}}
  end
end
