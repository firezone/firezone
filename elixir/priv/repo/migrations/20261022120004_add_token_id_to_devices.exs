defmodule Portal.Repo.Migrations.AddTokenIdToDevices do
  @moduledoc """
  One column for the token a device last connected with, whichever table it
  lives in today. Backfilled from the two role-specific columns, which keep
  being written until every caller reads this one.

  No foreign key yet: gateway token ids do not exist in client_tokens until
  the tables are merged, and the key is added with that copy.
  """
  use Ecto.Migration

  @disable_ddl_transaction true

  def up do
    alter table(:devices) do
      add(:token_id, :binary_id)
    end

    execute("""
    UPDATE devices SET token_id = COALESCE(client_token_id, gateway_token_id)
    WHERE token_id IS NULL AND (client_token_id IS NOT NULL OR gateway_token_id IS NOT NULL)
    """)

    create_if_not_exists(
      index(:devices, [:account_id, :token_id],
        where: "token_id IS NOT NULL",
        concurrently: true
      )
    )
  end

  def down do
    alter table(:devices) do
      remove(:token_id)
    end
  end
end
