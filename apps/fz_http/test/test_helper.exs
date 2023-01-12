Ecto.Adapters.SQL.Sandbox.mode(FzHttp.Repo, :manual)
Mox.defmock(OpenIDConnect.Mock, for: OpenIDConnect.MockBehaviour)
Bureaucrat.start(writer: Firezone.ApiBlueprintWriter, default_path: "../../api.apib")
ExUnit.start(formatters: [ExUnit.CLIFormatter, Bureaucrat.Formatter])
