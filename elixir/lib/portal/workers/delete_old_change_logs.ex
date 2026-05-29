defmodule Portal.Workers.DeleteOldChangeLogs do
  @moduledoc """
  Oban worker that deletes change_logs older than 90 days.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 1,
    unique: [period: :infinity, states: [:available, :scheduled, :executing, :retryable]]

  alias __MODULE__.Database

  require Logger

  @impl Oban.Worker
  def perform(_job) do
    {count, _} = Database.delete_old_change_logs()

    Logger.info("Deleted #{count} old change_logs")

    :ok
  end

  defmodule Database do
    import Ecto.Query
    alias Portal.ChangeLog
    alias Portal.Safe

    def delete_old_change_logs do
      from(cl in ChangeLog, as: :change_logs)
      |> where([change_logs: cl], cl.timestamp < ago(90, "day"))
      |> Safe.unscoped()
      |> Safe.delete_all()
    end
  end
end
