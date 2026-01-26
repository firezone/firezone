defmodule Portal.Billing.Stripe.ProcessedEvents.ProcessedEvent do
  @moduledoc """
  Schema for tracking processed Stripe webhook events.
  Ensures idempotency and chronological ordering of event processing.
  """
  # credo:disable-for-this-file Credo.Check.Warning.MissingChangesetFunction
  use Ecto.Schema

  @primary_key {:stripe_event_id, :string, []}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "processed_stripe_events" do
    field :event_type, :string
    field :processed_at, :utc_datetime_usec
    field :stripe_customer_id, :string
    field :event_created_at, :utc_datetime
    field :livemode, :boolean, default: false

    timestamps()
  end
end
