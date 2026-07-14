defmodule Portal.Datadog.Sync do
  @moduledoc """
  Delivers log entries to a Datadog Logs intake for one log sink. See
  `Portal.LogSinks.Delivery` for the delivery semantics.
  """
  use Oban.Worker,
    queue: :datadog_sync,
    max_attempts: 1,
    unique: [
      period: :infinity,
      states: :incomplete,
      keys: [:log_sink_id]
    ]

  alias Portal.Datadog
  alias Portal.LogSinks.Delivery

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"log_sink_id" => log_sink_id}}) do
    case Delivery.get_sink(Datadog.LogSink, log_sink_id) do
      nil ->
        Logger.info("Datadog log sink not found, disabled, or account ineligible, skipping",
          datadog_log_sink_id: log_sink_id
        )

      sink ->
        Delivery.sync(sink, Datadog.APIClient)
    end

    :ok
  end

  def perform(_), do: :ok
end
