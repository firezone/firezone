defmodule PortalAPI.Integrations.Okta.WebhookController do
  use PortalAPI, :controller

  alias Portal.Okta
  require Logger

  @max_body_bytes 1_000_000
  @max_events 1_000

  # Okta proves it can reach the endpoint with a GET whose challenge header
  # must come back in the body.
  def verify(conn, _params) do
    conn = fetch_query_params(conn)

    with [challenge] <- get_req_header(conn, "x-okta-verification-challenge"),
         :ok <- Okta.Webhooks.verify(conn.query_params["directory_id"]) do
      json(conn, %{"verification" => challenge})
    else
      {:error, :not_found} -> send_resp(conn, 404, "Not Found")
      _ -> send_resp(conn, 400, "Bad Request: missing verification challenge")
    end
  end

  def handle_webhook(conn, _params) do
    conn = fetch_query_params(conn)

    case read_body(conn, length: @max_body_bytes) do
      {:ok, body, conn} ->
        handle_body(conn, conn.query_params["directory_id"], body)

      {:more, _, conn} ->
        send_resp(conn, 413, "Request Entity Too Large")

      {:error, reason} ->
        Logger.info("Okta webhook body could not be read", reason: inspect(reason))
        send_resp(conn, 400, "Bad Request")
    end
  end

  defp handle_body(conn, directory_id, body) do
    authorization = conn |> get_req_header("authorization") |> List.first()

    with {:ok, %{"data" => %{"events" => events}}} when is_list(events) <- JSON.decode(body),
         true <- length(events) <= @max_events,
         :ok <- Okta.Webhooks.handle_events(directory_id, authorization, events) do
      send_resp(conn, 204, "")
    else
      false ->
        send_resp(conn, 413, "Request Entity Too Large: too many events")

      {:error, :unauthorized} ->
        send_resp(conn, 401, "Unauthorized")

      {:error, :not_found} ->
        send_resp(conn, 404, "Not Found")

      {:ok, _other} ->
        send_resp(conn, 400, "Bad Request: missing events")

      {:error, reason} ->
        Logger.info("Okta webhook rejected", reason: inspect(reason))
        send_resp(conn, 400, "Bad Request: invalid JSON")
    end
  end
end
