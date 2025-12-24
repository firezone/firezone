defmodule PortalWeb.Plugs.FetchUserAgent do
  @behaviour Plug
  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    case get_req_header(conn, "user-agent") do
      [user_agent | _] -> assign(conn, :user_agent, user_agent)
      _ -> conn
    end
  end
end
