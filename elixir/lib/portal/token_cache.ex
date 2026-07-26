defmodule Portal.TokenCache do
  @moduledoc """
  Caches access tokens until five minutes before expiration.

  Fetches are serialized in the GenServer so concurrent callers for the same
  token do not stampede identity-provider endpoints.
  """
  use GenServer

  @expiry_margin_seconds 300
  @call_timeout :timer.minutes(5)

  def start_link(opts) do
    GenServer.start_link(__MODULE__, nil, Keyword.put_new(opts, :name, __MODULE__))
  end

  @doc """
  Returns a cached token or calls `fetch_fun` to obtain one.

  The fetch function must return a token with either a relative lifetime:
  `{:ok, %{token: token, expires_in: seconds}}`, or an absolute expiration:
  `{:ok, %{token: token, expires_at: unix_seconds}}`. It may instead return
  `{:error, reason}`. When the cache process is not running, the token is
  fetched directly without caching.
  """
  def fetch(server, cache_key, fetch_fun) when is_function(fetch_fun, 0) do
    case GenServer.whereis(server) do
      nil -> fetch_without_cache(fetch_fun)
      server -> GenServer.call(server, {:fetch, cache_key, fetch_fun}, @call_timeout)
    end
  rescue
    exception -> {:error, exception}
  end

  @impl true
  def init(nil), do: {:ok, %{}}

  @impl true
  def handle_call({:fetch, cache_key, fetch_fun}, _from, state) do
    case cached_token(state, cache_key) do
      {:ok, token} ->
        {:reply, {:ok, token}, state}

      :miss ->
        case fetch_token(fetch_fun) do
          {:ok, token, expires_at} ->
            {:reply, {:ok, token}, Map.put(state, cache_key, {token, expires_at})}

          {:error, _reason} = error ->
            {:reply, error, state}
        end
    end
  rescue
    exception -> {:reply, {:error, exception}, state}
  end

  defp fetch_token(fetch_fun) do
    case fetch_fun.() do
      {:ok, %{token: token, expires_in: expires_in}} ->
        expires_at = System.system_time(:second) + seconds(expires_in)
        {:ok, token, expires_at}

      {:ok, %{token: token, expires_at: expires_at}} ->
        {:ok, token, seconds(expires_at)}

      {:error, _reason} = error ->
        error
    end
  end

  defp fetch_without_cache(fetch_fun) do
    case fetch_token(fetch_fun) do
      {:ok, token, _expires_at} -> {:ok, token}
      {:error, _reason} = error -> error
    end
  end

  defp cached_token(state, cache_key) do
    now = System.system_time(:second)

    case Map.get(state, cache_key) do
      {token, expires_at} when expires_at - @expiry_margin_seconds > now ->
        {:ok, token}

      _ ->
        :miss
    end
  end

  defp seconds(value) when is_integer(value), do: value
  defp seconds(value) when is_binary(value), do: String.to_integer(value)
end
