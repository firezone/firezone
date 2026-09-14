defmodule PortalAPI.Plugs.MCPAuth do
  @moduledoc """
  Authenticates an MCP request from its OAuth access token.

  Separate from `PortalAPI.Plugs.Auth` because the two accept different
  credentials on purpose. The REST API takes API tokens; this endpoint takes
  only tokens minted for it by the portal's authorization server, and checks
  that the token names this server as its audience. Accepting a token issued for
  something else, even a valid one, is the confused deputy the audience check
  exists to prevent.

  A rejected request carries a `WWW-Authenticate` challenge, which is how a
  client discovers where to authenticate.
  """

  import Plug.Conn

  alias Portal.Authentication
  alias Portal.Authentication.Context
  alias Portal.Authentication.Credential
  alias Portal.Authentication.Subject
  alias PortalAPI.MCP

  def init(opts), do: opts

  def call(conn, _opts) do
    context =
      Context.build(conn.remote_ip, conn.assigns[:user_agent], conn.req_headers, :mcp)

    with ["Bearer " <> encoded_token] <- get_req_header(conn, "authorization"),
         {:ok, subject} <- Authentication.authenticate(encoded_token, context),
         :ok <- validate_audience(subject) do
      assign(conn, :subject, subject)
    else
      _other -> unauthorized(conn)
    end
  end

  defp validate_audience(%Subject{credential: %Credential.OAuthToken{resource: resource}}) do
    if resource == MCP.resource_uri() do
      :ok
    else
      {:error, :wrong_audience}
    end
  end

  defp validate_audience(%Subject{}), do: {:error, :wrong_credential}

  defp unauthorized(conn) do
    conn
    |> put_resp_header("www-authenticate", MCP.challenge())
    |> PortalAPI.ProblemDetails.send(
      401,
      "An OAuth access token issued for this MCP server is required."
    )
  end
end
