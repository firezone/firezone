Code.require_file("../migrations/helpers/log_table_migration.exs", __DIR__)

defmodule Portal.Repo.Migrations.BackfillLogTables do
  use Ecto.Migration

  require Logger

  # Each batch and its checkpoint commit together. A failed or interrupted
  # migration resumes those checkpoints when Ecto reruns it.
  @disable_ddl_transaction true
  @batch_size 5_000

  def up do
    execute(fn ->
      for source <- ~w[session_logs api_request_logs change_logs] do
        Logger.info("Starting backfill and verification for #{source}")
        backfill(source, 0)
      end
    end)
  end

  # Copied rows are still maintained by the source triggers. Reverting this
  # migration must not remove those rows or undo a later table cutover.
  def down, do: :ok

  defp backfill(source, batches) do
    case Portal.Repo.Migrations.LogTableMigration.step(source, @batch_size) do
      :progress ->
        if rem(batches + 1, 100) == 0 do
          Logger.info("Processed #{batches + 1} backfill/verification batches for #{source}")
        end

        backfill(source, batches + 1)

      result when result in [:ready, :cutover] ->
        Logger.info("Finished backfill and verification for #{source}: #{result}")

      :busy ->
        raise "#{source} migration or partition maintenance is already running; retry the migration"
    end
  end
end
