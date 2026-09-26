defmodule PortalAPI.Plugs.MetricsAuth do
  @moduledoc """
  Authenticates a gateway metrics report from its Bearer token.

  Verification is stateless: the token is checked against the configured
  signing key and carries all the attribution the report needs, so nothing is
  read from the database. It runs before the body is read, so invalid or
  expired credentials are rejected without buffering the request.
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
