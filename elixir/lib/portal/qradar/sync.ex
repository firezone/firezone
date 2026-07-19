defmodule Portal.QRadar.Sync do
  @moduledoc """
  Delivers log entries to an IBM QRadar HTTP Receiver for one log sink. See
  `Portal.LogSinks.Delivery` for the delivery semantics.
  """
  use Oban.Worker,
    queue: :qradar_sync,
    max_attempts: 1,
    unique: [
      period: :infinity,
      states: :incomplete,
      keys: [:log_sink_id]
    ]

  alias Portal.LogSinks.Delivery
  alias Portal.QRadar

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"log_sink_id" => log_sink_id}}) do
    case Delivery.get_sink(QRadar.LogSink, log_sink_id) do
      nil ->
        Logger.info("QRadar log sink not found, disabled, or account ineligible, skipping",
          qradar_log_sink_id: log_sink_id
        )

      sink ->
        Delivery.sync(sink, QRadar.APIClient)
    end

    :ok
  end

  def perform(_), do: :ok
end
