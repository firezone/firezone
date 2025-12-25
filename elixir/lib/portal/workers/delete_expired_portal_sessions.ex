defmodule Portal.Workers.DeleteExpiredPortalSessions do
  @moduledoc """
  Oban worker that deletes expired portal sessions.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [period: :infinity, states: [:available, :scheduled, :executing, :retryable]]

  alias __MODULE__.DB

  require Logger

  @impl Oban.Worker
  def perform(_job) do
    {count, _} = DB.delete_expired_sessions()

    Logger.info("Deleted #{count} expired portal sessions")

    :ok
  end

  defmodule DB do
    import Ecto.Query
    alias Portal.PortalSession
    alias Portal.Safe

    def delete_expired_sessions do
      from(s in PortalSession, as: :sessions)
      |> where([sessions: s], s.expires_at <= ^DateTime.utc_now())
      |> Safe.unscoped()
      |> Safe.delete_all()
    end
  end
end
