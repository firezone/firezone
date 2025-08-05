defmodule Domain.Billing.Stripe.ProcessedEvents do
  @moduledoc """
  Context for tracking processed Stripe webhook events.
  Provides idempotency and chronological ordering capabilities.
  """

  import Ecto.Query, warn: false
  alias Domain.Repo
  alias Domain.Billing.Stripe.ProcessedEvents.ProcessedEvent

  @doc """
  Checks if a Stripe event has already been processed by event ID.
  """
  def event_processed?(stripe_event_id) do
    ProcessedEvent.Query.all()
    |> ProcessedEvent.Query.by_event_id(stripe_event_id)
    |> Repo.exists?()
  end

  @doc """
  Gets a processed event by Stripe event ID.
  """
  def get_by_stripe_event_id(stripe_event_id) do
    ProcessedEvent.Query.all()
    |> ProcessedEvent.Query.by_event_id(stripe_event_id)
    |> Repo.one()
  end

  @doc """
  Creates a processed event record.
  """
  def create_processed_event(attrs \\ %{}) do
    %ProcessedEvent{}
    |> ProcessedEvent.Changeset.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Gets the latest processed event for a customer (by Stripe customer ID).
  """
  def get_latest_for_stripe_customer(nil), do: nil

  def get_latest_for_stripe_customer(stripe_customer_id) do
    ProcessedEvent.Query.all()
    |> ProcessedEvent.Query.by_latest_event(stripe_customer_id)
    |> Repo.one()
  end

  @doc """
  Gets the latest processed event for a Stripe customer by event type.
  """
  def get_latest_for_stripe_customer(nil, _event_type), do: nil

  def get_latest_for_stripe_customer(customer_id, event_type) do
    ProcessedEvent.Query.all()
    |> ProcessedEvent.Query.by_latest_event_type(customer_id, event_type)
    |> Repo.one()
  end

  @doc """
  Cleans up processed events older than specified days.
  """
  def cleanup_old_events(days_old \\ 30) do
    cutoff_date = DateTime.utc_now() |> DateTime.add(-days_old, :day)

    {count, _} =
      ProcessedEvent.Query.all()
      |> ProcessedEvent.Query.by_cutoff_date(cutoff_date)
      |> Repo.delete_all()

    {:ok, count}
  end
end
