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
      from(s in ClientSession, as: :client_sessions)
      |> where([client_sessions: s], s.inserted_at < ago(90, "day"))
      |> where(
        [client_sessions: s],
        exists(
          from(newer in ClientSession,
            where: newer.client_id == parent_as(:client_sessions).client_id,
            where: newer.inserted_at > parent_as(:client_sessions).inserted_at,
            select: 1
          )
        )
      )
      |> Safe.unscoped()
      |> Safe.delete_all()
    end
  end
end
