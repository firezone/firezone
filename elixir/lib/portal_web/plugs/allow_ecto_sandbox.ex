defmodule PortalWeb.Plugs.AllowEctoSandbox do
  @behaviour Plug

  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    with [user_agent] <- get_req_header(conn, "user-agent"),
         %{owner: test_pid} <- Phoenix.Ecto.SQL.Sandbox.decode_metadata(user_agent) do
      Process.put(:last_caller_pid, test_pid)
      conn
    else
      _ -> conn
    end
  end
end
