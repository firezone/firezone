defmodule Portal.Workers.DeleteExpiredAuthenticationCacheEntries do
  @moduledoc """
  Oban worker that deletes expired authentication cache entries.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [period: :infinity, states: [:available, :scheduled, :executing, :retryable]]

  require Logger
  alias __MODULE__.Database

  @impl Oban.Worker
  def perform(_job) do
    count = Database.delete_expired_entries()

    Logger.info("Deleted #{count} expired authentication_cache_entries")

    :ok
  end

  defmodule Database do
    import Ecto.Query
    alias Portal.AuthenticationCacheEntry
    alias Portal.Safe

    def delete_expired_entries do
      {count, _} =
        from(entry in AuthenticationCacheEntry,
          where: entry.expires_at <= ^DateTime.utc_now()
        )
        |> Safe.unscoped()
        |> Safe.delete_all()

      count
    end
  end
end
