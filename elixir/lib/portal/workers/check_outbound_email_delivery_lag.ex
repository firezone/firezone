defmodule Portal.Workers.CheckOutboundEmailDeliveryLag do
  @moduledoc """
  Oban worker that logs an error when outbound emails stop getting delivery
  reports from ACS. An Azure log alert pages on-call from that error.

  Reports normally arrive about two minutes after a send, and slow recipient
  servers can delay one for hours. So a single slow delivery is not a lag, but
  several messages without a report are.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 1,
    unique: [period: :infinity, states: :incomplete]

  alias __MODULE__.Database

  require Logger

  @threshold_seconds 600
  @lookback_seconds 3600
  @min_lagging_messages 3

  @impl Oban.Worker
  def perform(_job) do
    now = DateTime.utc_now()
    lagging_before = DateTime.add(now, -@threshold_seconds, :second)
    lookback_start = DateTime.add(now, -@lookback_seconds, :second)

    case Database.lagging_messages(lagging_before, lookback_start) do
      %{count: count, oldest_inserted_at: oldest} when count >= @min_lagging_messages ->
        Logger.error("Outbound email delivery reports are lagging",
          lagging_messages: count,
          oldest_pending_seconds: DateTime.diff(now, oldest, :second)
        )

      _ ->
        :ok
    end

    :ok
  end

  defmodule Database do
    import Ecto.Query
    alias Portal.OutboundEmailDelivery
    alias Portal.Safe

    def lagging_messages(lagging_before, lookback_start) do
      from(d in OutboundEmailDelivery,
        where: d.status == :pending,
        where: d.inserted_at <= ^lagging_before,
        where: d.inserted_at > ^lookback_start,
        select: %{
          count: fragment("count(DISTINCT ?)", d.message_id),
          oldest_inserted_at: min(d.inserted_at)
        }
      )
      |> Safe.unscoped()
      |> Safe.one()
    end
  end
end
