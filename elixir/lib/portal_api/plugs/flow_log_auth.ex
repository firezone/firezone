defmodule PortalAPI.Plugs.FlowLogAuth do
  @moduledoc """
  Authenticates a flow-log ingestion request from its Bearer token.

  This plug intentionally runs before `Plug.Parsers`: the token is entirely in
  the request headers, so invalid or expired credentials can be rejected
  without buffering or decoding the request body.
  """

  import Plug.Conn
  require Logger

  alias Portal.FlowLogToken
  alias PortalAPI.ProblemDetails

  def init(opts), do: opts

  def call(conn, _opts) do
    token = bearer_token(conn)

    with {:ok, token} <- token,
         {:ok, claims, account} <- FlowLogToken.verify(token),
         :ok <- ensure_uploads_enabled(claims) do
      conn
      |> assign(:flow_log_claims, claims)
      |> assign(:flow_log_account, account)
    else
      {:error, reason} ->
        unauthorized(conn, reason, token)
    end
  end

  defp bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> {:ok, token}
      _ -> {:error, :missing}
    end
  end

  defp unauthorized(conn, reason, token) do
    account_id =
      case token do
        {:ok, token} -> FlowLogToken.unverified_account_id(token)
        _ -> nil
      end

    Logger.info("Flow log upload unauthorized", reason: reason, account_id: account_id)
    Portal.Telemetry.flow_log_upload_unauthorized(reason)

    detail =
      if reason == :uploads_disabled,
        do: "Flow log uploads are not enabled for this authorization",
        else: "Authentication credentials were missing or invalid."

    ProblemDetails.send(conn, 401, detail)
  end

  defp ensure_uploads_enabled(%{"uploads_enabled" => true}), do: :ok
  defp ensure_uploads_enabled(_claims), do: {:error, :uploads_disabled}
end
