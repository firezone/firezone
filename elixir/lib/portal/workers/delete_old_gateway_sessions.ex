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
      from(s in GatewaySession, as: :gateway_sessions)
      |> where([gateway_sessions: s], s.inserted_at < ago(90, "day"))
      |> where(
        [gateway_sessions: s],
        exists(
          from(newer in GatewaySession,
            where: newer.gateway_id == parent_as(:gateway_sessions).gateway_id,
            where: newer.inserted_at > parent_as(:gateway_sessions).inserted_at,
            select: 1
          )
        )
      )
      |> Safe.unscoped()
      |> Safe.delete_all()
    end
  end
end
