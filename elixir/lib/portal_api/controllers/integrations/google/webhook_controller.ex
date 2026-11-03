defmodule PortalAPI.Integrations.Google.WebhookController do
  use PortalAPI, :controller

  alias Portal.Google
  require Logger

  @max_body_bytes 1_000_000

  def handle_webhook(conn, _params) do
    conn = fetch_query_params(conn)

    token = header(conn, "x-goog-channel-token")
    state = header(conn, "x-goog-resource-state")

    # Dropped notifications still get a 200 so the response does not reveal
    # whether the directory or the token was wrong.
    case Google.Webhooks.authenticate(conn.query_params["directory_id"], token) do
      {:ok, directory} -> receive_notification(conn, directory, state)
      {:error, :unauthorized} -> send_resp(conn, 200, "")
    end
  end

  defp receive_notification(conn, directory, state) do
    case read_body(conn, length: @max_body_bytes) do
      {:ok, body, conn} ->
        Portal.Conn.wrap_errors(conn, &handle_body(&1, directory, state, body))

      {:more, _, conn} ->
        send_resp(conn, 413, "Request Entity Too Large")

      {:error, reason} ->
        Logger.info("Google webhook rejected", reason: inspect(reason))
        send_resp(conn, 400, "Bad Request")
    end
  end

  defp handle_body(conn, directory, state, body) do
    :ok = Google.Webhooks.handle_notification(directory, state, decode(body))
    send_resp(conn, 200, "")
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
