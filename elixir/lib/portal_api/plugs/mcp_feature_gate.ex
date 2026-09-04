defmodule PortalAPI.Plugs.MCPFeatureGate do
  @moduledoc """
  Hides the MCP transport unless its global rollout flag is enabled.

  This runs before authentication and body parsing so a disabled deployment
  behaves as though the `/mcp` routes do not exist.
  """

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    if Portal.Features.enabled?(:mcp) do
      conn
    else
      conn
      |> send_resp(404, "Not Found")
      |> halt()
    end
  end
end
