defmodule PortalAPI.Plugs.MetricsAuth do
  @moduledoc """
  Authenticates a gateway metrics export from its Bearer token.

  This plug intentionally runs before `Plug.Parsers`: the token is entirely in
  the request headers, so invalid or expired credentials can be rejected
  without buffering or decoding the request body.
  """

  import Plug.Conn

  alias Portal.MetricsToken
  alias PortalAPI.ProblemDetails

  def init(opts), do: opts

  def call(conn, _opts) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         {:ok, claims} <- MetricsToken.verify(token) do
      assign(conn, :metrics_claims, claims)
    else
      _ -> ProblemDetails.send(conn, 401, "Authentication credentials were missing or invalid.")
    end
  end
end
