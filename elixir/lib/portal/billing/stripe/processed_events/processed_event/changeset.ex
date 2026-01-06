defmodule Portal.Billing.Stripe.ProcessedEvents.ProcessedEvent.Changeset do
  import Ecto.Changeset

  @required_fields [
    :stripe_event_id,
    :event_type,
    :processed_at,
    :event_created_at,
    :livemode
  ]

  @optional_fields [
    :stripe_customer_id
  ]
  def changeset(processed_event, attrs) do
    processed_event
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_length(:stripe_event_id, max: 255)
    |> validate_length(:event_type, max: 100)
    |> validate_length(:stripe_customer_id, max: 255)
    |> validate_format(:stripe_event_id, ~r/^evt_/, message: "is not a valid event id")
    |> validate_format(:stripe_customer_id, ~r/^cus_/, message: "is not a valid customer id")
  end
end
