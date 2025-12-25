defmodule Portal.Repo.Migrations.CreateProcessedStripeEvents do
  use Ecto.Migration

  def up do
    create table(:processed_stripe_events, primary_key: false) do
      add(:stripe_event_id, :string, null: false, primary_key: true)
      add(:event_type, :string, null: false)
      add(:processed_at, :utc_datetime, null: false, default: fragment("NOW()"))
      add(:stripe_customer_id, :string, null: true)
      add(:event_created_at, :utc_datetime, null: false)
      add(:livemode, :boolean, null: false, default: false)

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:processed_stripe_events, [:stripe_customer_id, :event_type]))
    create(index(:processed_stripe_events, [:stripe_customer_id, :event_created_at]))
  end

  def down do
    execute("DROP TABLE IF EXISTS processed_stripe_events")
  end
end
