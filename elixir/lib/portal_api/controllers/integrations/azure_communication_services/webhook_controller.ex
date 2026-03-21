defmodule PortalAPI.Integrations.AzureCommunicationServices.WebhookController do
  use PortalAPI, :controller

  alias Portal.AzureCommunicationServices
  require Logger

  def handle_webhook(conn, _params) do
    with [event_type] <- get_req_header(conn, "aeg-event-type"),
         {:ok, body, conn} <- read_body(conn),
         {:ok, events} <- decode_events(body) do
      case dispatch_event_type(conn, event_type, events) do
        {:error, :invalid_secret} ->
          send_resp(conn, 401, "Unauthorized")

        {:error, :invalid_validation_event} ->
          send_resp(conn, 400, "Bad Request: invalid validation event")

        {:error, reason} ->
          Logger.error("ACS Event Grid webhook failed", reason: inspect(reason))
          send_resp(conn, 500, "Internal Error")

        conn ->
          conn
      end
    else
      [] ->
        send_resp(conn, 400, "Bad Request: missing aeg-event-type header")

      {:more, _, _} ->
        send_resp(conn, 413, "Request Entity Too Large")

      {:error, :invalid_json} ->
        send_resp(conn, 400, "Bad Request: invalid JSON")

      {:error, reason} ->
        Logger.error("ACS Event Grid webhook failed", reason: inspect(reason))
        send_resp(conn, 500, "Internal Error")
    end
  end

  defp dispatch_event_type(conn, "SubscriptionValidation", events) do
    case validation_code(events) do
      {:ok, code} -> json(conn, %{validationResponse: code})
      {:error, reason} -> {:error, reason}
    end
  end

  defp dispatch_event_type(conn, "Notification", events) do
    with :ok <- verify_secret(conn),
         :ok <- AzureCommunicationServices.handle_event_grid_events(events) do
      send_resp(conn, 200, "")
    end
  end

  defp dispatch_event_type(conn, "Unsubscribe", _events) do
    send_resp(conn, 200, "")
  end

  defp dispatch_event_type(conn, _event_type, _events) do
    send_resp(conn, 400, "Bad Request: unsupported aeg-event-type")
  end

  defp verify_secret(conn) do
    case AzureCommunicationServices.event_grid_webhook_signing_secret() do
      nil ->
        Logger.error("ACS Event Grid webhook secret is not configured")
        {:error, :invalid_secret}

      secret ->
        conn = fetch_query_params(conn)

        if Plug.Crypto.secure_compare(conn.params["secret"] || "", secret) do
          :ok
        else
          {:error, :invalid_secret}
        end
    end
  end

  defp validation_code([%{"data" => %{"validationCode" => code}} | _]) when is_binary(code),
    do: {:ok, code}

  defp validation_code(_events), do: {:error, :invalid_validation_event}

  defp decode_events(body) do
    case JSON.decode(body) do
      {:ok, events} -> {:ok, events}
      {:error, _reason} -> {:error, :invalid_json}
    end
  end
end
