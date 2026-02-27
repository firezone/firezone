defmodule Portal.AuthenticationCache do
  @moduledoc """
  Database-backed cache for short-lived authentication state.

  Entries are stored in Postgres with per-entry TTL and can be consumed
  atomically with `pop/1`.
  """

  alias __MODULE__.Database

  @default_ttl_ms :timer.minutes(15)

  @type key :: String.t()
  @type value :: map()

  @spec oidc_auth_key(String.t()) :: String.t()
  def oidc_auth_key(state) when is_binary(state), do: "oidc_auth:" <> state

  @spec verification_key(String.t()) :: String.t()
  def verification_key(token) when is_binary(token), do: "verification:" <> token

  @spec put(key(), value(), keyword()) :: :ok
  def put(key, value, opts \\ []) when is_binary(key) and is_map(value) do
    ttl_ms = Keyword.get(opts, :ttl, @default_ttl_ms)

    if is_integer(ttl_ms) and ttl_ms > 0 do
      now = DateTime.utc_now()
      expires_at = DateTime.add(now, ttl_ms, :millisecond)

      attrs = %{
        key: key,
        value: value,
        expires_at: expires_at,
        inserted_at: now
      }

      Database.put(attrs)
    else
      raise ArgumentError, "ttl must be a positive integer in milliseconds"
    end
  end

  @spec get(key()) :: {:ok, value()} | :error
  def get(key) when is_binary(key) do
    Database.get(key)
  end

  @spec pop(key()) :: {:ok, value()} | :error
  def pop(key) when is_binary(key) do
    Database.pop(key)
  end

  @spec delete(key()) :: :ok
  def delete(key) when is_binary(key) do
    Database.delete(key)
  end

  defmodule Database do
    import Ecto.Query
    alias Portal.AuthenticationCacheEntry
    alias Portal.Safe

    def put(attrs) do
      conflict_updates = [set: [value: attrs.value, expires_at: attrs.expires_at]]

      {1, _} =
        Safe.unscoped()
        |> Safe.insert_all(AuthenticationCacheEntry, [attrs],
          on_conflict: conflict_updates,
          conflict_target: :key
        )

      :ok
    end

    def get(key) do
      query =
        from(entry in AuthenticationCacheEntry,
          where: entry.key == ^key and entry.expires_at > ^DateTime.utc_now(),
          select: entry.value
        )

      case query |> Safe.unscoped() |> Safe.one() do
        nil -> :error
        value -> {:ok, value}
      end
    end

    def pop(key) do
      query =
        from(entry in AuthenticationCacheEntry,
          where: entry.key == ^key and entry.expires_at > ^DateTime.utc_now(),
          select: entry.value
        )

      case query |> Safe.unscoped() |> Safe.delete_all() do
        {1, [value]} -> {:ok, value}
        {0, []} -> :error
      end
    end

    def delete(key) do
      from(entry in AuthenticationCacheEntry, where: entry.key == ^key)
      |> Safe.unscoped()
      |> Safe.delete_all()

      :ok
    end
  end
end
