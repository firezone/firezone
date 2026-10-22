defmodule Portal.Repo.Migrations.CreateSessionLogs do
  use Ecto.Migration

  def change do
    create table(:session_logs, primary_key: false) do
      add(:account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        primary_key: true,
        null: false
      )

      add(:event_id, :bytea, primary_key: true, null: false)
      add(:timestamp, :timestamptz, null: false)
      add(:context, :string, null: false)

      # Snapshot of the connecting principal and its context, taken at session
      # creation. Intentionally FK-free (it lives in the JSONB): actors,
      # devices, tokens, and auth providers can be deleted, but session history
      # must survive them.
      add(:subject, :map, null: false)
    end

    create(constraint(:session_logs, :event_id_is_12_bytes, check: "octet_length(event_id) = 12"))

    create(
      constraint(:session_logs, :session_logs_context_chk,
        check: "context IN ('client', 'gateway', 'portal')"
      )
    )

    # The (account_id, event_id) primary key already covers account-scoped
    # reads; this index only serves retention, which deletes across all
    # accounts by timestamp.
    create(index(:session_logs, [:timestamp]))
  end
end
