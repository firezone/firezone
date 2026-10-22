defmodule Portal.NewRelic.Sync do
  @moduledoc """
  Delivers log entries to the New Relic Log API for one log sink. See
  `Portal.LogSinks.Delivery` for the delivery semantics.
  """
  use Oban.Worker,
    queue: :newrelic_sync,
    max_attempts: 1,
    unique: [
      period: :infinity,
      states: :incomplete,
      keys: [:log_sink_id]
    ]

  alias Portal.LogSinks.Delivery
  alias Portal.NewRelic

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"account_id" => account_id, "log_sink_id" => log_sink_id}}) do
    case Delivery.get_sink(NewRelic.LogSink, account_id, log_sink_id) do
      nil ->
        Logger.info("New Relic log sink not found, disabled, or account ineligible, skipping",
          account_id: account_id,
          newrelic_log_sink_id: log_sink_id
        )

      sink ->
        Delivery.sync(sink, NewRelic.APIClient)
    end

    :ok
  end

  def perform(_), do: :ok
end
