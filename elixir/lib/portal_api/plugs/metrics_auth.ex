defmodule PortalAPI.Plugs.MetricsAuth do
  @moduledoc """
  Authenticates a `POST /v1/metrics` request from its `Portal.MetricsToken`
  Bearer token, before the body is read.
  """

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         {:ok, claims} <- Portal.MetricsToken.verify(token) do
      assign(conn, :metrics_claims, claims)
    else
      _ ->
        PortalAPI.ProblemDetails.send(
          conn,
          401,
          "Authentication credentials were missing or invalid."
        )
    end
  end
end
