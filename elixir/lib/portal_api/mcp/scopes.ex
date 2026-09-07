defmodule PortalAPI.MCP.Scopes do
  @moduledoc """
  Which tools a request's credential may reach.

  Scopes come from the access token, which carries what the resource owner
  consented to on the browser consent screen. They are the same per-entity
  scopes the REST API uses, so a tool and the equivalent REST call require the
  same thing.

  Tools outside the granted scopes are left out of `tools/list` entirely, which
  the specification allows: a server's tool set may vary by the authorization
  presented on the request.

  This only filters what is advertised. A `tools/call` is dispatched back
  through `PortalAPI.Router`, where `PortalAPI.Plugs.Scope` checks the same
  scopes again, so a tool reached without being listed is still refused.
  """

  alias Portal.Scope
  alias PortalAPI.MCP.Tool

  @doc "Whether the granted `scopes` permit `tool`."
  def permits?(scopes, %Tool{} = tool) do
    case required_scope(tool) do
      {:ok, required} -> Scope.satisfies?(scopes, required)
      :error -> false
    end
  end

  @doc """
  The scope `tool` requires, for the challenge sent when it is missing.

  A tool with no entity cannot be scoped, and is refused rather than treated as
  freely available.
  """
  def required_scope(%Tool{entity: nil}), do: :error
  def required_scope(%Tool{entity: entity, method: method}), do: {:ok, Scope.required(entity, method)}
end
