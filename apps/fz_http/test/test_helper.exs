# Delete screenshots from previous acceptance test executions
Path.join(File.cwd!(), "screenshots") |> File.rm_rf!()

Bureaucrat.start(
  writer: Firezone.DocusaurusWriter,
  default_path: "../../docs/docs/reference/rest-api"
)

Ecto.Adapters.SQL.Sandbox.mode(FzHttp.Repo, :manual)
ExUnit.start(formatters: [ExUnit.CLIFormatter, JUnitFormatter, Bureaucrat.Formatter])
