defmodule Domain.Repo.Migrations.MoveStripeCustomerId do
  use Ecto.Migration

  def change do
    # --- Step 1: Add a new top-level stripe_customer_id column ---
    alter table(:accounts) do
      add(:stripe_customer_id, :string)
    end

    # --- Step 2: Copy data from nested field to the new column ---
    execute("""
      UPDATE accounts
      SET stripe_customer_id = metadata -> 'stripe' ->> 'customer_id'
      WHERE metadata -> 'stripe' ->> 'product_name' IN ('Team', 'Enterprise')
      AND metadata -> 'stripe' ->> 'customer_id' IS NOT NULL
    """)

    # --- Step 3: Remove the old nested field ---
    alter table(:accounts) do
      remove(:metadata)
    end

    # --- Step 4: Add a new index on the new column ---
    create(
      index(:accounts, [:stripe_customer_id],
        unique: true,
        where: "stripe_customer_id IS NOT NULL"
      )
    )
  end
end
