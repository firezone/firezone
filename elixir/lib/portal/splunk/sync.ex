defmodule Portal.Splunk.Sync do
  @moduledoc """
  Delivers log entries to a Splunk HEC endpoint for one log sink. See
  `Portal.LogSinks.Delivery` for the delivery semantics.
  """
  use Oban.Worker,
    queue: :splunk_sync,
    max_attempts: 1,
    unique: [
      period: :infinity,
      states: :incomplete,
      keys: [:log_sink_id]
    ]

  alias Portal.LogSinks.Delivery
  alias Portal.Splunk

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"log_sink_id" => log_sink_id}}) do
    case Delivery.get_sink(Splunk.LogSink, log_sink_id) do
      nil ->
        Logger.info("Splunk log sink not found, disabled, or account ineligible, skipping",
          splunk_log_sink_id: log_sink_id
        )

      sink ->
        Delivery.sync(sink, Splunk.APIClient)
    end

    :ok
  end

  def perform(_), do: :ok
end
