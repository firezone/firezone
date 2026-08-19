defmodule PortalAPI.MCP.Scopes do
  @moduledoc """
  The MCP scopes a request has been granted.

  Reading is granted to any caller the REST API already authenticates. Writing
  is gated separately, because a model that can create a Policy or delete an
  Actor is a much larger blast radius than one that can only look.

  Tools outside the granted scopes are left out of `tools/list` entirely, which
  is explicitly allowed: a server's tool set may vary by the authorization
  presented on the request.
  """

  alias Portal.Authentication.Subject

  @doc "Scopes granted to `subject`, as a list of `:read` and `:write`."
  def granted(%Subject{}) do
    if Portal.Features.enabled?(:mcp_writes) do
      [:read, :write]
    else
      [:read]
    end
  end
end
