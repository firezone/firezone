defmodule Portal.Mailer.RateLimiter do
  use GenServer

  @default_ets_table_name __MODULE__.ETS

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    ets_table_name = Keyword.get(opts, :ets_table_name, @default_ets_table_name)
    prune_interval = Keyword.get(opts, :prune_interval, :timer.seconds(60))

    table =
      :ets.new(ets_table_name, [
        :named_table,
        :ordered_set,
        :public,
        read_concurrency: true,
        write_concurrency: true
      ])

    :ok = schedule_tick(prune_interval)

    {:ok, %{table: table, prune_interval: prune_interval}}
  end

  @impl true
  def handle_info(:prune_expired_counters, %{prune_interval: prune_interval} = state) do
    _ = prune_expired_counters()
    :ok = schedule_tick(prune_interval)
    {:noreply, state}
  end

  defp schedule_tick(prune_interval) do
    Process.send_after(self(), :prune_expired_counters, prune_interval)
    :ok
  end

  @doc false
  def prune_expired_counters(ets_table_name \\ @default_ets_table_name) do
    now = :erlang.system_time(:millisecond)
    match_spec = [{{:"$1", :"$2", :"$3"}, [], [{:"=<", :"$3", now}]}]
    :ets.select_delete(ets_table_name, match_spec)
  end

  @doc false
  def prune(ets_table_name \\ @default_ets_table_name) do
    _ = :ets.delete_all_objects(ets_table_name)
    :ok
  end

  @doc """
  Prevents the callback from being executed more than `limit` times within `interval`.

  Every time callback is executed, the counter is incremented and its expiration is extended,
  this means that if the caller MUST wait before calling the function again or it will be rate limited
  all the time.
  """
  def rate_limit(key, limit, interval, callback, ets_table_name \\ @default_ets_table_name) do
    now = :erlang.system_time(:millisecond)
    expires_at = now + interval

    counter =
      case :ets.lookup(ets_table_name, key) do
        [] ->
          create_counter(ets_table_name, key, expires_at)

        [{^key, _counter, currently_expires_at}] when currently_expires_at <= now ->
          delete_counter(ets_table_name, key)

        [{^key, _counter, _expires_at}] ->
          update_counter(ets_table_name, key, expires_at)
      end

    if counter > limit do
      {:error, :rate_limited}
    else
      {:ok, callback.()}
    end
  end

  def reset_rate_limit(key, ets_table_name \\ @default_ets_table_name) do
    _ = delete_counter(ets_table_name, key)
    :ok
  end

  defp delete_counter(ets_table_name, key) do
    :ets.delete(ets_table_name, key)
    1
  end

  defp create_counter(ets_table_name, key, expires_at) do
    :ets.insert(ets_table_name, {key, 1, expires_at})
    1
  end

  defp update_counter(ets_table_name, key, expires_at) do
    [counter, _expires_at] =
      :ets.update_counter(
        ets_table_name,
        key,
        [
          {2, 1},
          {3, 1, 0, expires_at}
        ],
        {nil, 0, expires_at}
      )

    counter
  end
end
