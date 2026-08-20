defmodule PortalAPI.OAuthMetadataController do
  @moduledoc """
  Publishes this MCP server's OAuth protected resource metadata (RFC 9728).

  Unauthenticated by design: a client reads this before it has any credential,
  to learn which authorization server can issue one.
  """

  use PortalAPI, :controller

  alias Portal.OAuth.Scope
  alias PortalAPI.MCP

  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, _params) do
    conn
    |> put_resp_header("cache-control", "public, max-age=3600")
    |> json(%{
      resource: MCP.resource_uri(),
      authorization_servers: [MCP.authorization_server()],
      scopes_supported: Scope.supported(),
      bearer_methods_supported: ["header"]
    })
  end
end
