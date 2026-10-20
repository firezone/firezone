defmodule Portal.Workers.ProductAnalyticsSnapshot do
  @moduledoc """
  Oban worker that sends a daily product usage snapshot of every account to PostHog.

  Only scheduled when PostHog is configured. Events carry deterministic UUIDs, so a
  retried run does not duplicate the snapshots that already went through.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [period: :infinity, states: :incomplete]

  alias Portal.Analytics.AccountSnapshot
  alias Portal.Analytics.PostHog

  @impl Oban.Worker
  def perform(_job) do
    if PostHog.enabled?() do
      AccountSnapshot.send_all()
    else
      :ok
    end
  end
end
