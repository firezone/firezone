Code.require_file("../migrations/helpers/log_table_migration.exs", __DIR__)

defmodule Portal.Repo.Migrations.CutOverLogTables do
  use Ecto.Migration

  @disable_ddl_transaction true

  def up do
    execute(fn ->
      # Fresh databases need to replay the historical cutover. Populated databases
      # must complete it on the preceding release before cleanup can be deployed.
      for source <- ~w[session_logs api_request_logs change_logs] do
        [[partitioned]] =
          repo().query!(
            "SELECT EXISTS (SELECT 1 FROM pg_partitioned_table WHERE partrelid = $1::text::regclass)",
            [source]
          ).rows

        unless partitioned do
          [[populated]] = repo().query!("SELECT EXISTS (SELECT 1 FROM #{source})").rows

          if populated,
            do: raise("Complete #{source} cutover with the preceding release before cleanup")
        end
      end

      for source <- ~w[session_logs api_request_logs change_logs] do
        case Portal.Repo.Migrations.LogTableMigration.cutover(source) do
          result when result in [:cutover, :already_cut_over] -> :ok
          :busy -> raise "#{source} partition maintenance is running; retry the migration"
        end
      end
    end)
  end

  def down, do: raise("Restoring legacy log tables would lose writes accepted after cutover")
end
