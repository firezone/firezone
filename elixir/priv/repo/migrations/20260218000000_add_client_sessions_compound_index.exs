defmodule Portal.Repo.Migrations.AddClientSessionsCompoundIndex do
  use Ecto.Migration

  @disable_ddl_transaction true

  def change do
    # The original migration created an index named client_sessions_client_id_inserted_at_index
    # but only indexed [:client_id], leaving out :inserted_at. The lateral subquery in the
    # clients index page does:
    #
    #   WHERE client_id = $1 AND account_id = $2 ORDER BY inserted_at DESC LIMIT 1
    #
    # Without a compound index on (account_id, client_id, inserted_at DESC), Postgres must
    # scan all rows for a given client_id, filter by account_id, then sort.
    execute(
      "DROP INDEX CONCURRENTLY IF EXISTS client_sessions_client_id_inserted_at_index",
      """
      CREATE INDEX CONCURRENTLY client_sessions_client_id_inserted_at_index
      ON client_sessions (client_id)
      """
    )

    create(
      index(:client_sessions, [:account_id, :client_id, {:desc, :inserted_at}],
        name: :client_sessions_account_id_client_id_inserted_at_index,
        concurrently: true
      )
    )

    # clients_account_id_index on (account_id) is redundant — the PK (account_id, id)
    # already covers all account-scoped prefix scans.
    execute(
      "DROP INDEX CONCURRENTLY IF EXISTS clients_account_id_index",
      "CREATE INDEX CONCURRENTLY clients_account_id_index ON clients (account_id)"
    )

    # gateway_sessions has the same missing-compound-index bug as client_sessions:
    # gateway_sessions_gateway_id_index only indexes (gateway_id). The preload query does:
    #
    #   WHERE account_id IN (...) AND gateway_id IN (...) DISTINCT ON gateway_id ORDER BY inserted_at DESC
    #
    # A compound (account_id, gateway_id, inserted_at DESC) index allows seek-and-stop per gateway.
    execute(
      "DROP INDEX CONCURRENTLY IF EXISTS gateway_sessions_gateway_id_index",
      """
      CREATE INDEX CONCURRENTLY gateway_sessions_gateway_id_index
      ON gateway_sessions (gateway_id)
      """
    )

    create(
      index(:gateway_sessions, [:account_id, :gateway_id, {:desc, :inserted_at}],
        name: :gateway_sessions_account_id_gateway_id_inserted_at_index,
        concurrently: true
      )
    )
  end
end
