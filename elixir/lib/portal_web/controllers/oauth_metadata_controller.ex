defmodule PortalWeb.OAuthMetadataController do
  @moduledoc """
  Publishes this portal's OAuth 2.0 Authorization Server Metadata (RFC 8414).

  Read before a client holds any credential, so it is unauthenticated.
  """

  use PortalWeb, :controller

  alias Portal.Scope

  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, _params) do
    issuer = PortalWeb.Endpoint.url()

    conn
    |> put_resp_header("cache-control", "public, max-age=3600")
    |> json(%{
      issuer: issuer,
      authorization_endpoint: issuer <> "/oauth/authorize",
      token_endpoint: issuer <> "/oauth/token",
      revocation_endpoint: issuer <> "/oauth/revoke",
      scopes_supported: Scope.all(),
      response_types_supported: ["code"],
      grant_types_supported: ["authorization_code", "refresh_token"],
      code_challenge_methods_supported: ["S256"],
      # Public clients only. There are no secrets to issue because a client is
      # identified by the metadata document it hosts.
      token_endpoint_auth_methods_supported: ["none"],
      client_id_metadata_document_supported: true,
      authorization_response_iss_parameter_supported: true
    })
  end
end
