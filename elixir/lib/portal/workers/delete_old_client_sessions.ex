defmodule Portal.Workers.DeleteOldClientSessions do
  @moduledoc """
  Oban worker that deletes client sessions older than 90 days.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [period: :infinity, states: [:available, :scheduled, :executing, :retryable]]

  alias __MODULE__.Database

  require Logger

  @impl Oban.Worker
  def perform(_job) do
    {count, _} = Database.delete_old_client_sessions()

    Logger.info("Deleted #{count} old client_sessions")

    :ok
  end

  defmodule Database do
    import Ecto.Query
    alias Portal.ClientSession
    alias Portal.Safe

    def delete_old_client_sessions do
      latest_per_client =
        from(s in ClientSession,
          select: %{
            id: s.id,
            rn:
              row_number()
              # id is a UUID so its ordering is arbitrary, but it provides a
              # deterministic tiebreaker when multiple sessions share the same
              # inserted_at (e.g. from a batch flush), ensuring exactly one is kept.
              |> over(
                partition_by: s.client_id,
                order_by: [desc: s.inserted_at, desc: s.id]
              )
          }
        )

      from(s in ClientSession, as: :client_sessions)
      |> join(:inner, [client_sessions: s], r in subquery(latest_per_client),
        on: r.id == s.id and r.rn > 1
      )
      |> where([client_sessions: s], s.inserted_at < ago(90, "day"))
      |> Safe.unscoped()
      |> Safe.delete_all()
    end
  end
end
