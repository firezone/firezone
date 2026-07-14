defmodule Portal.Sentinel.Sync do
  @moduledoc """
  Delivers log entries to Microsoft Sentinel via the Azure Monitor Logs
  Ingestion API for one log sink. See `Portal.LogSinks.Delivery` for the
  delivery semantics.
  """
  use Oban.Worker,
    queue: :sentinel_sync,
    max_attempts: 1,
    unique: [
      period: :infinity,
      states: :incomplete,
      keys: [:log_sink_id]
    ]

  alias Portal.LogSinks.Delivery
  alias Portal.Sentinel

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"log_sink_id" => log_sink_id}}) do
    case Delivery.get_sink(Sentinel.LogSink, log_sink_id) do
      nil ->
        Logger.info("Sentinel log sink not found, disabled, or account ineligible, skipping",
          sentinel_log_sink_id: log_sink_id
        )

      sink ->
        Delivery.sync(sink, Sentinel.APIClient)
    end

    :ok
  end

  def perform(_), do: :ok
end
