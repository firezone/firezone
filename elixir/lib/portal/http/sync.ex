defmodule Portal.HTTP.Sync do
  @moduledoc """
  Delivers log entries to a generic HTTPS endpoint for one log sink. See
  `Portal.LogSinks.Delivery` for the delivery semantics.
  """
  use Oban.Worker,
    queue: :http_sync,
    max_attempts: 1,
    unique: [
      period: :infinity,
      states: :incomplete,
      keys: [:log_sink_id]
    ]

  alias Portal.HTTP
  alias Portal.LogSinks.Delivery

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"log_sink_id" => log_sink_id}}) do
    case Delivery.get_sink(HTTP.LogSink, log_sink_id) do
      nil ->
        Logger.info("HTTP log sink not found, disabled, or account ineligible, skipping",
          http_log_sink_id: log_sink_id
        )

      sink ->
        Delivery.sync(sink, HTTP.APIClient)
    end

    :ok
  end

  def perform(_), do: :ok
end
