defmodule Portal.Workers.DeleteOldChangeLogs do
  @moduledoc """
  Oban worker that deletes change_logs older than 121 days.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 1,
    unique: [period: :infinity, states: :incomplete]

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
      # Queued and scheduled legacy jobs become no-ops after cutover. Retention
      # is then handled by dropping whole daily partitions.
      {:ok, %{rows: [[partitioned]]}} =
        Safe.unscoped()
        |> Safe.query(
          "SELECT EXISTS (SELECT 1 FROM pg_partitioned_table WHERE partrelid = to_regclass('change_logs'))",
          []
        )

      if partitioned, do: {0, nil}, else: delete_legacy_rows()
    end

    defp delete_legacy_rows do
      from(cl in ChangeLog, as: :change_logs)
      |> where(
        [change_logs: cl],
        cl.timestamp <
          fragment(
            "((CURRENT_TIMESTAMP AT TIME ZONE 'UTC')::date - 121)::timestamp AT TIME ZONE 'UTC'"
          )
      )
      |> Safe.unscoped()
      |> Safe.delete_all()
    end
  end
end
