Ecto.Adapters.SQL.Sandbox.mode(FzHttp.Repo, :manual)
Mox.defmock(OpenIDConnect.Mock, for: OpenIDConnect.MockBehaviour)

# Delete screenshots from previous acceptance test executions
Path.join(File.cwd!(), "screenshots") |> File.rm_rf!()

Bureaucrat.start(
  writer: Firezone.DocusaurusWriter,
  default_path: "../../docs/docs/reference/api"
)

ExUnit.start(formatters: [ExUnit.CLIFormatter, Bureaucrat.Formatter])
