defmodule Mix.Tasks.PopulateAccount do
  use Mix.Task

  @shortdoc "Populate the database with a generated account"

  @impl true
  def run(args) do
    Mix.Task.run("loadpaths")
    Portal.Dev.AccountPopulation.ensure_runtime_started()

    case Portal.Dev.AccountPopulation.main(args) do
      {:ok, summary} ->
        IO.puts("Created account population")
        IO.puts("  account_id: #{summary.account_id}")
        IO.puts("  slug: #{summary.slug}")
        IO.puts("  name: #{summary.name}")
        IO.puts("  plan: #{summary.plan}")
        IO.puts("  level: #{summary.level}")
        IO.puts("  admin_email: #{summary.admin_email}")

        Enum.each(summary.counts, fn {key, value} ->
          IO.puts("  #{key}: #{value}")
        end)

      {:error, reason} ->
        Mix.raise("account population failed: #{inspect(reason)}")
    end
  end
end
