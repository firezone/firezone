defmodule PortalAPI.Integrations.Entra.WebhookController do
  use PortalAPI, :controller

  alias Portal.Entra
  require Logger

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
    with {:ok, body, conn} <- read_body(conn),
         {:ok, %{"value" => notifications}} when is_list(notifications) <- JSON.decode(body) do
      :ok = Entra.Webhooks.handle_notifications(directory_id, notifications)
      send_resp(conn, 202, "")
    else
      # coveralls-ignore-start
      # Defensive: only triggered by a payload exceeding read_body/2's default
      # 8MB length, which Graph never sends.
      {:more, _, _} ->
        send_resp(conn, 413, "Request Entity Too Large")

      # coveralls-ignore-stop

      {:ok, _other} ->
        send_resp(conn, 400, "Bad Request: missing notifications")

      {:error, reason} ->
        Logger.info("Entra webhook rejected", reason: inspect(reason))
        send_resp(conn, 400, "Bad Request: invalid JSON")
    end
  end
end
