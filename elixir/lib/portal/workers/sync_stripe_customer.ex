defmodule Portal.Workers.SyncStripeCustomer do
  @moduledoc """
  Sends the account ID and current slug of an account to its Stripe customer,
  with retries. Enqueued when the slug changes.
  """

  # A running job may have read the account before the change that enqueues
  # the next one, so only jobs that have not started yet absorb new changes.
  use Oban.Worker,
    queue: :default,
    max_attempts: 10,
    unique: [
      period: :infinity,
      states: [:available, :scheduled, :retryable],
      keys: [:account_id]
    ]

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"account_id" => account_id}}) do
    Portal.Billing.sync_stripe_customer(account_id)
  end
end
