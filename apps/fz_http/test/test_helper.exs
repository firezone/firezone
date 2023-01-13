Ecto.Adapters.SQL.Sandbox.mode(FzHttp.Repo, :manual)
Mox.defmock(OpenIDConnect.Mock, for: OpenIDConnect.MockBehaviour)

Bureaucrat.start(
  writer: Firezone.DocusaurusWriter,
  default_path: "../../docs/docs/reference/api"
)

ExUnit.start(formatters: [ExUnit.CLIFormatter, Bureaucrat.Formatter])
