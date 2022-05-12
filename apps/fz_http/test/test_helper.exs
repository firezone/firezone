Mox.defmock(OpenIDConnect.Mock, for: OpenIDConnect.MockBehaviour)

ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(FzHttp.Repo, :manual)
