# Delete screenshots from previous acceptance test executions
Path.join(File.cwd!(), "screenshots") |> File.rm_rf!()

Bureaucrat.start(
  writer: Web.Documentation.Generator,
  default_path: "../../www/docs/reference/rest-api"
)

Ecto.Adapters.SQL.Sandbox.mode(Domain.Repo, :manual)
ExUnit.start(formatters: [ExUnit.CLIFormatter, JUnitFormatter, Bureaucrat.Formatter])
