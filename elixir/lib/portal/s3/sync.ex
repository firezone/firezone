defmodule Portal.S3.Sync do
  @moduledoc """
  Delivers log entries to an Amazon S3 bucket for one log sink. See
  `Portal.LogSinks.Delivery` for the delivery semantics.
  """
  use Oban.Worker,
    queue: :s3_sync,
    max_attempts: 1,
    unique: [
      period: :infinity,
      states: :incomplete,
      keys: [:log_sink_id]
    ]

  alias Portal.LogSinks.Delivery
  alias Portal.S3

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"log_sink_id" => log_sink_id}}) do
    case Delivery.get_sink(S3.LogSink, log_sink_id) do
      nil ->
        Logger.info("Amazon S3 log sink not found, disabled, or account ineligible, skipping",
          s3_log_sink_id: log_sink_id
        )

      sink ->
        Delivery.sync(sink, S3.APIClient)
    end

    :ok
  end

  def perform(_), do: :ok
end
