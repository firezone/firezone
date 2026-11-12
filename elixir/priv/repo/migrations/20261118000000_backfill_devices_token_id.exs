defmodule Portal.Repo.Migrations.BackfillDevicesTokenId do
  use Ecto.Migration

  @disable_ddl_transaction true
  @batch_size 5_000

  # Every node writes token_id since the previous deploy. Batches keep each
  # update short, because connects update devices all the time, and take
  # rows in the same order as the connect flush to avoid deadlocks.
  def up do
    backfill()
  end

  def down, do: :ok

  defp backfill do
    %{num_rows: count} =
      repo().query!(
        """
        UPDATE devices AS d
        SET token_id = COALESCE(d.client_token_id, d.gateway_token_id)
        FROM (
          SELECT account_id, id
          FROM devices
          WHERE token_id IS NULL
            AND (client_token_id IS NOT NULL OR gateway_token_id IS NOT NULL)
          ORDER BY account_id, id
          LIMIT $1
        ) AS batch
        WHERE d.account_id = batch.account_id AND d.id = batch.id
        """,
        [@batch_size],
        log: false
      )

    if count > 0, do: backfill()
  end
end
