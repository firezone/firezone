defmodule Portal.Workers.DeleteSubscription do
  @moduledoc """
  Oban worker that cancels Stripe subscriptions for a deleted account's Stripe customer.
  Enqueued by DeleteAccount after the account row is deleted.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 5,
    unique: [
      period: :infinity,
      states: :incomplete,
      keys: [:customer_id]
    ]

  alias Portal.Billing

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"customer_id" => customer_id}}) do
    Billing.cancel_subscriptions_by_customer_id(customer_id)
  end
end
