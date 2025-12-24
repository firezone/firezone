defmodule PortalAPI.Integrations.Stripe.WebhookController do
  use PortalAPI, :controller
  alias Portal.Billing
  require Logger

  @tolerance 300
  @scheme "v1"

  def handle_webhook(conn, _params) do
    with [signature_header] <- get_req_header(conn, "stripe-signature"),
         {:ok, body, conn} <- read_body(conn),
         {:ok, {timestamp, signatures}} <- fetch_timestamp_and_signatures(signature_header),
         :ok <- verify_timestamp(timestamp, @tolerance),
         secret = Billing.fetch_webhook_signing_secret!(),
         :ok <- verify_signatures(signatures, timestamp, body, secret),
         {:ok, payload} <- JSON.decode(body),
         :ok <- Billing.handle_events([payload]) do
      send_resp(conn, 200, "")
    else
      [] ->
        send_resp(conn, 400, "Bad Request: missing signature header")

      {:error, :missing_timestamp} ->
        send_resp(conn, 400, "Bad Request: missing timestamp")

      {:error, :missing_signatures} ->
        send_resp(conn, 400, "Bad Request: missing signatures")

      {:error, :stale_event} ->
        send_resp(conn, 400, "Bad Request: expired signature")

      {:error, :invalid_signature} ->
        send_resp(conn, 400, "Bad Request: invalid signature")

      reason ->
        :ok = Logger.error("Stripe webhook failed", reason: inspect(reason))
        send_resp(conn, 500, "Internal Error")
    end
  end

  defp fetch_timestamp_and_signatures(signature_header) do
    signature_header
    |> String.split(",")
    |> Enum.map(&String.split(&1, "="))
    |> Enum.reduce({nil, []}, fn
      ["t", timestamp], {nil, signatures} ->
        {String.to_integer(timestamp), signatures}

      [@scheme, signature], {timestamp, signatures} ->
        {timestamp, [signature | signatures]}

      _, acc ->
        acc
    end)
    |> case do
      {nil, _} ->
        {:error, :missing_timestamp}

      {_, []} ->
        {:error, :missing_signatures}

      {timestamp, signatures} ->
        {:ok, {timestamp, signatures}}
    end
  end

  defp verify_timestamp(timestamp, tolerance) do
    if timestamp < System.system_time(:second) - tolerance do
      {:error, :stale_event}
    else
      :ok
    end
  end

  defp verify_signatures(signatures, timestamp, payload, secret) do
    expected_signature = sign(timestamp, secret, payload)

    if Enum.any?(signatures, &Plug.Crypto.secure_compare(&1, expected_signature)) do
      :ok
    else
      {:error, :invalid_signature}
    end
  end

  @doc false
  def sign(timestamp, secret, payload) do
    hmac_sha256(secret, "#{timestamp}.#{payload}")
  end

  defp hmac_sha256(secret, payload) do
    :crypto.mac(:hmac, :sha256, secret, payload)
    |> Base.encode16(case: :lower)
  end
end
