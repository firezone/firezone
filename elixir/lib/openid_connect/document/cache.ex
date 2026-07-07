# Vendored from https://github.com/firezone/openid_connect, a fork of
# https://github.com/DockYard/openid_connect by DockYard, Inc.
# MIT licensed; see lib/openid_connect/LICENSE.md.
defmodule OpenIDConnect.Document.Cache do
  use GenServer
  alias OpenIDConnect.Document

  @max_size Application.compile_env(:portal, [OpenIDConnect, :document_cache_max_size], 1_000)

  @refresh_cooldown_seconds Application.compile_env(
                              :portal,
                              [OpenIDConnect, :jwks_refresh_cooldown_seconds],
                              60
                            )

  @doc "Starts the cache GenServer. Defaults to a registered name of `#{inspect(__MODULE__)}`."
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def init(_opts) do
    Process.send_after(self(), :gc, :timer.minutes(1))
    {:ok, %{}}
  end

  @doc "Inserts `document` under `uri`, scheduling its removal at the document's expiry."
  def put(pid \\ __MODULE__, uri, document) do
    GenServer.cast(pid, {:put, uri, document})
  end

  @doc "Returns the cached document for `uri`, bumping recency. Evicts expired entries on lookup."
  def fetch(pid \\ __MODULE__, uri) do
    GenServer.call(pid, {:fetch, uri})
  end

  @doc "Non-mutating lookup: returns the cached doc as-is, without bumping recency or evicting on expiry."
  def peek(pid \\ __MODULE__, uri) do
    GenServer.call(pid, {:peek, uri})
  end

  @doc "Returns the full cache state map. Primarily intended for introspection in tests."
  def flush(pid \\ __MODULE__) do
    GenServer.call(pid, :flush)
  end

  @doc "Empties the cache and cancels every scheduled removal timer."
  def clear(pid \\ __MODULE__) do
    GenServer.call(pid, :clear)
  end

  @doc "Removes the entry for `uri` (if any), canceling its removal timer."
  def delete(pid \\ __MODULE__, uri) do
    GenServer.call(pid, {:delete, uri})
  end

  @doc """
  Atomically gates JWKS refresh for `uri` behind a per-URI cooldown. Returns
  `true` and marks the attempt time if at least the configured cooldown has
  elapsed (or no prior attempt is recorded); returns `false` otherwise, or when
  `uri` is not cached.
  """
  def allow_refresh?(pid \\ __MODULE__, uri) do
    GenServer.call(pid, {:allow_refresh, uri})
  end

  def handle_cast({:put, uri, document}, state) do
    if document_expired?(document) do
      {:noreply, state}
    else
      # Preserve `last_refresh_at` across the put so a successful refetch doesn't
      # reset the cooldown an attacker is already serving time against.
      prior_refresh_at =
        case Map.get(state, uri) do
          {_ref, _fetched, prior, _doc} -> prior
          nil -> nil
        end

      state = evict(state, uri)
      expires_in_seconds = expires_in_seconds(document.expires_at)

      timer_ref =
        :erlang.start_timer(:timer.seconds(expires_in_seconds), self(), {:remove, uri})

      state = Map.put(state, uri, {timer_ref, DateTime.utc_now(), prior_refresh_at, document})
      {:noreply, state}
    end
  end

  def handle_call(:flush, _from, state) do
    {:reply, state, state}
  end

  def handle_call(:clear, _from, state) do
    for {_uri, {timer_ref, _last_fetched_at, _last_refresh_at, _document}} <- state do
      Process.cancel_timer(timer_ref)
    end

    {:reply, :ok, %{}}
  end

  def handle_call({:delete, uri}, _from, state) do
    {:reply, :ok, evict(state, uri)}
  end

  def handle_call({:fetch, uri}, _from, state) do
    case Map.fetch(state, uri) do
      {:ok, {timer_ref, _last_fetched_at, last_refresh_at, document}} ->
        if document_expired?(document) do
          {:reply, :error, evict(state, uri)}
        else
          state =
            Map.put(state, uri, {timer_ref, DateTime.utc_now(), last_refresh_at, document})

          {:reply, {:ok, document}, state}
        end

      :error ->
        {:reply, :error, state}
    end
  end

  def handle_call({:peek, uri}, _from, state) do
    reply =
      case Map.fetch(state, uri) do
        {:ok, {_timer_ref, _last_fetched_at, _last_refresh_at, document}} -> {:ok, document}
        :error -> :error
      end

    {:reply, reply, state}
  end

  def handle_call({:allow_refresh, uri}, _from, state) do
    case Map.fetch(state, uri) do
      {:ok, {timer_ref, last_fetched_at, last_refresh_at, document}} ->
        now = DateTime.utc_now()

        if refresh_cooldown_elapsed?(last_refresh_at, now) do
          state = Map.put(state, uri, {timer_ref, last_fetched_at, now, document})
          {:reply, true, state}
        else
          {:reply, false, state}
        end

      :error ->
        {:reply, false, state}
    end
  end

  # Only remove when the ref matches the current entry: a stale timer from a
  # previous entry for the same URI (e.g. one dropped by :gc without a cancel)
  # must not wipe a fresh entry.
  def handle_info({:timeout, timer_ref, {:remove, uri}}, state) do
    case Map.get(state, uri) do
      {^timer_ref, _last_fetched_at, _last_refresh_at, _document} ->
        {:noreply, Map.delete(state, uri)}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info(:gc, state) do
    state =
      if Enum.count(state) > @max_size do
        state
        |> Enum.sort_by(
          fn {_key, {_ref, last_fetched_at, _last_refresh_at, _document}} -> last_fetched_at end,
          {:desc, DateTime}
        )
        |> Enum.take(@max_size)
        |> Enum.into(%{})
      else
        state
      end

    Process.send_after(self(), :gc, :timer.minutes(1))

    {:noreply, state}
  end

  # Drops `uri` from state and cancels its timer. A timer that already fired is
  # harmless: its queued `{:timeout, ref, _}` no longer matches any entry.
  defp evict(state, uri) do
    case Map.pop(state, uri) do
      {nil, state} ->
        state

      {{timer_ref, _last_fetched_at, _last_refresh_at, _document}, state} ->
        Process.cancel_timer(timer_ref)
        state
    end
  end

  defp refresh_cooldown_elapsed?(nil, _now), do: true

  defp refresh_cooldown_elapsed?(last_refresh_at, now) do
    DateTime.diff(now, last_refresh_at, :second) >= @refresh_cooldown_seconds
  end

  defp expires_in_seconds(%DateTime{} = datetime) do
    max(DateTime.diff(datetime, DateTime.utc_now(), :second), 0)
  end

  defp document_expired?(%Document{expires_at: expires_at}) do
    DateTime.compare(expires_at, DateTime.utc_now()) != :gt
  end
end
