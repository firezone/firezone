defmodule Domain.Billing.Stripe.ProcessedEvents do
  @moduledoc """
  Context for tracking processed Stripe webhook events.
  Provides idempotency and chronological ordering capabilities.
  """

  import Ecto.Query, warn: false
  alias Domain.Repo
  alias Domain.Billing.Stripe.ProcessedEvent

  @doc """
  Checks if a Stripe event has already been processed by event ID.
  """
  def event_processed?(stripe_event_id) do
    Repo.exists?(
      from p in ProcessedEvent,
        where: p.stripe_event_id == ^stripe_event_id
    )
  end

  @doc """
  Gets a processed event by Stripe event ID.
  """
  def get_by_stripe_event_id(stripe_event_id) do
    Repo.get_by(ProcessedEvent, stripe_event_id: stripe_event_id)
  end

  @doc """
  Creates a processed event record.
  """
  def create_processed_event(attrs \\ %{}) do
    %ProcessedEvent{}
    |> ProcessedEvent.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Gets the latest processed event for a customer (by Stripe customer ID).
  """
  def get_latest_for_stripe_customer(nil), do: nil

  def get_latest_for_stripe_customer(stripe_customer_id) do
    from(p in ProcessedEvent,
      where: p.stripe_customer_id == ^stripe_customer_id,
      order_by: [desc: p.event_created_at],
      limit: 1
    )
    |> Repo.one()
  end

  @doc """
  Gets the latest processed event for a Stripe customer by event type.
  """
  def get_latest_for_stripe_customer(nil, _event_type), do: nil

  def get_latest_for_stripe_customer(customer_id, event_type) do
    from(p in ProcessedEvent,
      where: p.customer_id == ^customer_id and p.event_type == ^event_type,
      order_by: [desc: p.event_created_at],
      limit: 1
    )
    |> Repo.one()
  end

  @doc """
  Cleans up processed events older than specified days.
  """
  def cleanup_old_events(days_old \\ 30) do
    cutoff_date = DateTime.utc_now() |> DateTime.add(-days_old, :day)

    {count, _} =
      from(p in ProcessedEvent,
        where: p.processed_at < ^cutoff_date
      )
      |> Repo.delete_all()

    {:ok, count}
  end
end
