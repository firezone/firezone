defmodule PortalAPI.Integrations.Entra.WebhookController do
  use PortalAPI, :controller

  alias Portal.Entra
  require Logger

  @max_body_bytes 1_000_000
  @max_notifications 1_000

  def handle_webhook(conn, _params) do
    conn = fetch_query_params(conn)

    case conn.query_params do
      # Graph validates the endpoint by posting `?validationToken=...` and
      # expects the token echoed back as plain text.
      %{"validationToken" => token} when is_binary(token) ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(200, token)

      %{} = params ->
        handle_notifications(conn, params["directory_id"])
    end
  end

  defp handle_notifications(conn, directory_id) do
    case read_body(conn, length: @max_body_bytes) do
      {:ok, body, conn} ->
        handle_notification_body(conn, directory_id, body)

      {:more, _, conn} ->
        send_resp(conn, 413, "Request Entity Too Large")

      {:error, reason} ->
        Logger.info("Entra webhook body could not be read", reason: inspect(reason))
        send_resp(conn, 400, "Bad Request")
    end
  end

  defp handle_notification_body(conn, directory_id, body) do
    with {:ok, %{"value" => notifications}} when is_list(notifications) <- JSON.decode(body),
         true <- length(notifications) <= @max_notifications do
      :ok = Entra.Webhooks.handle_notifications(directory_id, notifications)
      send_resp(conn, 202, "")
    else
      false ->
        send_resp(conn, 413, "Request Entity Too Large: too many notifications")

      {:ok, _other} ->
        send_resp(conn, 400, "Bad Request: missing notifications")

      {:error, reason} ->
        Logger.info("Entra webhook rejected", reason: inspect(reason))
        send_resp(conn, 400, "Bad Request: invalid JSON")
    end
  end
end
