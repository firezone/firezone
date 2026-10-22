defmodule PortalAPI.Plugs.FlowLogAuth do
  @moduledoc """
  Authenticates a flow-log ingestion request from its Bearer token.

  This plug intentionally runs before `Plug.Parsers`: the token is entirely in
  the request headers, so invalid or expired credentials can be rejected
  without buffering or decoding the request body.
  """

  import Plug.Conn

  alias Portal.FlowLogToken
  alias PortalAPI.ProblemDetails

  def init(opts), do: opts

  def call(conn, _opts) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         {:ok, claims} <- FlowLogToken.verify(token),
         :ok <- ensure_uploads_enabled(claims) do
      assign(conn, :flow_log_claims, claims)
    else
      {:error, :uploads_disabled} ->
        ProblemDetails.send(conn, 401, "Flow log uploads are not enabled for this authorization")

      _ -> ProblemDetails.send(conn, 401, "Authentication credentials were missing or invalid.")
    end
  end

  defp ensure_uploads_enabled(%{"uploads_enabled" => true}), do: :ok
  defp ensure_uploads_enabled(_claims), do: {:error, :uploads_disabled}
end
