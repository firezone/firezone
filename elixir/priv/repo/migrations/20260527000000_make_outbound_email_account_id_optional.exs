defmodule Portal.Repo.Migrations.MakeOutboundEmailAccountIdOptional do
  use Ecto.Migration

  def up do
    # Drop the composite FK from deliveries so we can change outbound_emails' PK.
    execute("""
    ALTER TABLE outbound_email_deliveries
      DROP CONSTRAINT outbound_email_deliveries_message_id_fkey
    """)

    execute("""
    ALTER TABLE outbound_emails
      DROP CONSTRAINT outbound_emails_pkey,
      DROP CONSTRAINT outbound_emails_account_id_fkey,
      ADD CONSTRAINT outbound_emails_pkey PRIMARY KEY (message_id),
      ALTER COLUMN account_id DROP NOT NULL,
      ADD CONSTRAINT outbound_emails_account_id_fkey
        FOREIGN KEY (account_id) REFERENCES accounts(id) ON DELETE SET NULL
    """)

    execute("""
    ALTER TABLE outbound_email_deliveries
      DROP CONSTRAINT outbound_email_deliveries_account_id_fkey,
      DROP CONSTRAINT outbound_email_deliveries_pkey,
      ADD CONSTRAINT outbound_email_deliveries_pkey PRIMARY KEY (message_id, email),
      ALTER COLUMN account_id DROP NOT NULL,
      ADD CONSTRAINT outbound_email_deliveries_account_id_fkey
        FOREIGN KEY (account_id) REFERENCES accounts(id) ON DELETE SET NULL,
      ADD CONSTRAINT outbound_email_deliveries_message_id_fkey
        FOREIGN KEY (message_id) REFERENCES outbound_emails(message_id) ON DELETE CASCADE
    """)
  end

  def down do
    execute("DELETE FROM outbound_emails WHERE account_id IS NULL")
    execute("DELETE FROM outbound_email_deliveries WHERE account_id IS NULL")

    execute("""
    ALTER TABLE outbound_email_deliveries
      DROP CONSTRAINT outbound_email_deliveries_message_id_fkey,
      DROP CONSTRAINT outbound_email_deliveries_account_id_fkey,
      DROP CONSTRAINT outbound_email_deliveries_pkey,
      ALTER COLUMN account_id SET NOT NULL,
      ADD CONSTRAINT outbound_email_deliveries_pkey PRIMARY KEY (message_id, account_id, email),
      ADD CONSTRAINT outbound_email_deliveries_account_id_fkey
        FOREIGN KEY (account_id) REFERENCES accounts(id) ON DELETE CASCADE
    """)

    execute("""
    ALTER TABLE outbound_emails
      DROP CONSTRAINT outbound_emails_pkey,
      DROP CONSTRAINT outbound_emails_account_id_fkey,
      ALTER COLUMN account_id SET NOT NULL,
      ADD CONSTRAINT outbound_emails_pkey PRIMARY KEY (account_id, message_id),
      ADD CONSTRAINT outbound_emails_account_id_fkey
        FOREIGN KEY (account_id) REFERENCES accounts(id) ON DELETE CASCADE
    """)

    execute("""
    ALTER TABLE outbound_email_deliveries
      ADD CONSTRAINT outbound_email_deliveries_message_id_fkey
        FOREIGN KEY (message_id, account_id) REFERENCES outbound_emails(message_id, account_id)
        ON DELETE CASCADE
    """)
  end
end
