defmodule PortalAPI.MCP.Scopes do
  @moduledoc """
  The MCP scopes a request has been granted.

  These come from the access token, which carries what the resource owner
  actually consented to on the browser consent screen. The `:mcp_writes` feature
  flag is ANDed with that: it is an operator kill switch, not a grant, so it can
  take write access away but never add it.

  Tools outside the granted scopes are left out of `tools/list` entirely, which
  the specification allows: a server's tool set may vary by the authorization
  presented on the request.
  """

  alias Portal.Authentication.Credential
  alias Portal.Authentication.Subject
  alias Portal.OAuth.Scope

  @doc "Scopes granted to `subject`, as a list of `:read` and `:write`."
  def granted(%Subject{credential: %Credential{type: :oauth_token, scopes: scopes}}) do
    if Scope.satisfies?(scopes, [Scope.write()]) and Portal.Features.enabled?(:mcp_writes) do
      [:read, :write]
    else
      [:read]
    end
  end

  def granted(%Subject{}), do: [:read]

  @doc "The OAuth scope a tool requires, for the challenge sent when it is missing."
  def required_scope(%PortalAPI.MCP.Tool{write?: true}), do: Scope.write()
  def required_scope(%PortalAPI.MCP.Tool{}), do: Scope.read()
end
