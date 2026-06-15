defmodule Portal.Workers.DeleteOldSessionLogs do
  @moduledoc """
  Oban worker that deletes session_logs older than 90 days.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 1,
    unique: [period: :infinity, states: :incomplete]

  alias __MODULE__.Database

  require Logger

  @impl Oban.Worker
  def perform(_job) do
    {count, _} = Database.delete_old_session_logs()

    Logger.info("Deleted #{count} old session_logs")

    :ok
  end

  defmodule Database do
    import Ecto.Query
    alias Portal.SessionLog
    alias Portal.Safe

    def delete_old_session_logs do
      from(sl in SessionLog, as: :session_logs)
      |> where([session_logs: sl], sl.timestamp < ago(90, "day"))
      |> Safe.unscoped()
      |> Safe.delete_all()
    end
  end
end
