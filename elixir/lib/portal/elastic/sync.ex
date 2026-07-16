defmodule Portal.Elastic.Sync do
  @moduledoc """
  Delivers log entries to an Elasticsearch cluster for one log sink. See
  `Portal.LogSinks.Delivery` for the delivery semantics.
  """
  use Oban.Worker,
    queue: :elastic_sync,
    max_attempts: 1,
    unique: [
      period: :infinity,
      states: :incomplete,
      keys: [:log_sink_id]
    ]

  alias Portal.Elastic
  alias Portal.LogSinks.Delivery

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"log_sink_id" => log_sink_id}}) do
    case Delivery.get_sink(Elastic.LogSink, log_sink_id) do
      nil ->
        Logger.info("Elastic log sink not found, disabled, or account ineligible, skipping",
          elastic_log_sink_id: log_sink_id
        )

      sink ->
        Delivery.sync(sink, Elastic.APIClient)
    end

    :ok
  end

  def perform(_), do: :ok
end
