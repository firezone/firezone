defmodule PortalAPI.Integrations.Google.WebhookController do
  use PortalAPI, :controller

  alias Portal.Google
  require Logger

  @max_body_bytes 1_000_000

  def handle_webhook(conn, _params) do
    conn = fetch_query_params(conn)

    headers = %{
      token: header(conn, "x-goog-channel-token"),
      state: header(conn, "x-goog-resource-state")
    }

    case read_body(conn, length: @max_body_bytes) do
      {:ok, body, conn} ->
        :ok = Google.Webhooks.handle_notification(conn.query_params["directory_id"], headers, decode(body))
        send_resp(conn, 200, "")

      {:more, _, conn} ->
        send_resp(conn, 413, "Request Entity Too Large")

      {:error, reason} ->
        Logger.info("Google webhook rejected", reason: inspect(reason))
        send_resp(conn, 400, "Bad Request")
    end
  end

  # Google sends an empty body for the initial sync message.
  defp decode(""), do: nil

  defp decode(body) do
    case JSON.decode(body) do
      {:ok, %{} = decoded} -> decoded
      _ -> nil
    end
  end

  defp header(conn, name) do
    case get_req_header(conn, name) do
      [value | _] -> value
      [] -> nil
    end
  end
end
