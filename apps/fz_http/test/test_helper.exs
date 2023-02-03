# Delete screenshots from previous acceptance test executions
Path.join(File.cwd!(), "screenshots") |> File.rm_rf!()

Bureaucrat.start(
  writer: DocsGenerator,
  default_path: "../../www/docs/docs/reference/rest-api"
)

Ecto.Adapters.SQL.Sandbox.mode(FzHttp.Repo, :manual)
ExUnit.start(formatters: [ExUnit.CLIFormatter, JUnitFormatter, Bureaucrat.Formatter])
