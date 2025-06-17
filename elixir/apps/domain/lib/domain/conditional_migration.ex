defmodule Domain.ConditionalMigration do
  @moduledoc """
    We don't want to run some migrations automatically on application boot. To do
    that, we implement a conditional migration module that can be used to
    conditionally run migrations based on the environment or other criteria.

    The reason this module was introduced is to avoid issues where the migration might
    take a while to run, as in the following cases:

      - Modifying tables that may queries taking locks on them (looking at you, auth_providers)
      - Modifying large amounts of data
      - Creating indexes on large tables that can't be done concurrently

    NOTE: Use this module with care. You *need to* ensure that the application will run without
    error if this migration is not run.

    Usage:

    ```elixir
    defmodule Domain.Repo.Migrations.MyConditionalMigration do
      use Domain.ConditionalMigration

      def up do
        # Your migration logic here
      end

      def down do
        # Your rollback logic here
      end
    end
    ```
  """

  defmacro __using__(_opts) do
    quote do
      use Ecto.Migration
      require Logger

      @env_var "RUN_MANUAL_MIGRATIONS"

      def up do
        if should_run?() do
          do_up()
        else
          Logger.warning("""
          Skipping migration #{__MODULE__}
          To run manually, set #{@env_var}=true and retry or run this migration from IEx:

          Ecto.Migrator.run(Domain.Repo, "apps/domain/priv/repo/migrations", :up, to: #{version()})
          """)
        end
      end

      def down do
        if should_run?() do
          do_down()
        else
          Logger.warning("""
          Skipping migration #{__MODULE__}
          To run manually, set #{@env_var}=true and retry or run this migration from IEx:

          Ecto.Migrator.run(Domain.Repo, "apps/domain/priv/repo/migrations", :down, to: #{version()})
          """)
        end
      end

      if Mix.env() == :prod do
        defp should_run? do
          System.get_env(@env_var) == "true"
        end
      else
        defp should_run?, do: true
      end

      defp version do
        __ENV__.file
        |> String.split("/")
        |> List.last()
        |> String.split("_")
        |> List.first()
      end
    end
  end
end
