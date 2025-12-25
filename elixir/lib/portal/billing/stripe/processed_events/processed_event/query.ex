defmodule Portal.Billing.Stripe.ProcessedEvents.ProcessedEvent.Query do
  import Ecto.Query
  alias Portal.Billing.Stripe.ProcessedEvents.ProcessedEvent

  def all do
    from(events in ProcessedEvent, as: :events)
  end

  def by_event_id(queryable, id) do
    where(queryable, [events: events], events.stripe_event_id == ^id)
  end

  def by_event_type(queryable, event_type) do
    where(queryable, [events: events], events.event_type == ^event_type)
  end

  def by_stripe_customer_id(queryable, stripe_customer_id) do
    where(queryable, [events: events], events.stripe_customer_id == ^stripe_customer_id)
  end

  def by_latest_event(queryable, stripe_customer_id) do
    by_stripe_customer_id(queryable, stripe_customer_id)
    |> order_by([events: events], desc: events.event_created_at)
    |> limit(1)
  end

  def by_latest_event_type(queryable, stripe_customer_id, event_type) do
    by_stripe_customer_id(queryable, stripe_customer_id)
    |> by_event_type(event_type)
    |> order_by([events: events], desc: events.event_created_at)
    |> limit(1)
  end

  def by_cutoff_date(queryable, cutoff_date) do
    where(queryable, [events: events], events.processed_at < ^cutoff_date)
  end
end
