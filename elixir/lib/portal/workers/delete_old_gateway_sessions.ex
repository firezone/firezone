defmodule Portal.Workers.DeleteOldGatewaySessions do
  @moduledoc """
  Oban worker that deletes gateway sessions older than 90 days.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [period: :infinity, states: [:available, :scheduled, :executing, :retryable]]

  alias __MODULE__.Database

  require Logger

  @impl Oban.Worker
  def perform(_job) do
    {count, _} = Database.delete_old_gateway_sessions()

    Logger.info("Deleted #{count} old gateway_sessions")

    :ok
  end

  defmodule Database do
    import Ecto.Query
    alias Portal.GatewaySession
    alias Portal.Safe

    def delete_old_gateway_sessions do
      latest_per_gateway =
        from(s in GatewaySession,
          select: %{
            id: s.id,
            rn:
              row_number()
              # id is a UUID so its ordering is arbitrary, but it provides a
              # deterministic tiebreaker when multiple sessions share the same
              # inserted_at (e.g. from a batch flush), ensuring exactly one is kept.
              |> over(
                partition_by: s.gateway_id,
                order_by: [desc: s.inserted_at, desc: s.id]
              )
          }
        )

      from(s in GatewaySession, as: :gateway_sessions)
      |> join(:inner, [gateway_sessions: s], r in subquery(latest_per_gateway),
        on: r.id == s.id and r.rn > 1
      )
      |> where([gateway_sessions: s], s.inserted_at < ago(90, "day"))
      |> Safe.unscoped()
      |> Safe.delete_all()
    end
  end
end
