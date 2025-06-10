# Delete screenshots from previous acceptance test executions
Path.join(File.cwd!(), "screenshots") |> File.rm_rf!()

Finch.start_link(name: TestPool)

Ecto.Adapters.SQL.Sandbox.mode(Domain.Repo, :manual)
ExUnit.start(formatters: [ExUnit.CLIFormatter, JUnitFormatter])
