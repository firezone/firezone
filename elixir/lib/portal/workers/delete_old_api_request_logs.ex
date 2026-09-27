defmodule Portal.Workers.DeleteOldAPIRequestLogs do
  @moduledoc """
  Oban worker that deletes api_request_logs older than 90 days.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 1,
    unique: [period: :infinity, states: :incomplete]

  alias __MODULE__.Database

  require Logger

  @impl Oban.Worker
  def perform(_job) do
    {count, _} = Database.delete_old_api_request_logs()

    Logger.info("Deleted #{count} old api_request_logs")

    :ok
  end

  defmodule Database do
    import Ecto.Query
    alias Portal.APIRequestLog
    alias Portal.Safe

    def delete_old_api_request_logs do
      # Queued and scheduled legacy jobs become no-ops after cutover. Retention
      # is then handled by dropping whole daily partitions.
      {:ok, %{rows: [[partitioned]]}} =
        Safe.unscoped()
        |> Safe.query(
          "SELECT EXISTS (SELECT 1 FROM pg_partitioned_table WHERE partrelid = to_regclass('api_request_logs'))",
          []
        )

      if partitioned, do: {0, nil}, else: delete_legacy_rows()
    end

    defp delete_legacy_rows do
      from(arl in APIRequestLog, as: :api_request_logs)
      |> where([api_request_logs: arl], arl.inserted_at < ago(90, "day"))
      |> Safe.unscoped()
      |> Safe.delete_all()
    end
  end
end
