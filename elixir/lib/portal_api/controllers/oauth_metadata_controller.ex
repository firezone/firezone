defmodule PortalAPI.OAuthMetadataController do
  @moduledoc """
  Publishes this MCP server's OAuth protected resource metadata (RFC 9728).

  Unauthenticated by design: a client reads this before it has any credential,
  to learn which authorization server can issue one.

  `scopes_supported` is deliberately absent, though RFC 9728 allows it. A client
  with no scopes configured asks for whatever this document advertises, so
  listing them here would have every permission pre-ticked and reduce the
  consent screen to a rubber stamp. The authorization server metadata still
  publishes the vocabulary for anyone who wants to discover it.
  """

  use PortalAPI, :controller

  alias PortalAPI.MCP

  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, _params) do
    conn
    |> put_resp_header("cache-control", "public, max-age=3600")
    |> json(%{
      resource: MCP.resource_uri(),
      authorization_servers: [MCP.authorization_server()],
      bearer_methods_supported: ["header"]
    })
  end
end
