defmodule PortalAPI.Integrations.YC.WebhookController do
  use PortalAPI, :controller
  alias Portal.Billing
  alias Portal.Mailer
  require Logger

  def handle_webhook(conn, _params) do
    case get_req_header(conn, "x-yc-signature") do
      [signature] ->
        case read_body(conn, length: 1_000_000) do
          {:ok, body, conn} ->
            Portal.Conn.wrap_errors(conn, &handle_body(&1, signature, body))

          {:more, _, conn} ->
            send_resp(conn, 413, "Request Entity Too Large")

          {:error, reason} ->
            Logger.error("YC deal webhook body could not be read", reason: inspect(reason))
            send_resp(conn, 500, "Internal Error")
        end

      _headers ->
        reject(conn, :invalid_signature_header)
    end
  end

  # Each YC deal signs with its own secret, so the deal ID is read from the
  # body before the signature is checked. Nothing else in the body is used
  # until the signature matches that deal's secret.
  defp handle_body(conn, signature, body) do
    secrets = Portal.Config.fetch_env!(:portal, :yc_deal_webhook_secrets)

    with {:ok, %{"deal_id" => deal_id} = payload} when is_integer(deal_id) <- JSON.decode(body),
         {:ok, secret} <- Map.fetch(secrets, to_string(deal_id)),
         true <- Plug.Crypto.secure_compare(String.downcase(signature), sign(secret, body)) do
      redeem(conn, payload)
    else
      :error -> reject(conn, :unknown_deal)
      false -> reject(conn, :invalid_signature)
      _invalid_payload -> send_resp(conn, 400, "Bad Request")
    end
  end

  defp reject(conn, reason) do
    Logger.warning("YC deal webhook failed authentication", reason: reason)
    send_resp(conn, 401, "Unauthorized")
  end

  defp redeem(conn, %{"id" => redemption_id, "deal_id" => deal_id} = payload)
       when is_integer(redemption_id) do
    case Map.fetch(Portal.Config.fetch_env!(:portal, :yc_deal_coupon_ids), to_string(deal_id)) do
      {:ok, coupon_id} ->
        create_code(conn, coupon_id, redemption_id, payload)

      :error ->
        Logger.error("YC deal webhook for an unknown deal", yc_deal_id: deal_id)

        conn
        |> put_status(422)
        |> json(%{message: "This deal isn't set up yet. Please email support@firezone.dev."})
    end
  end

  defp redeem(conn, _payload) do
    send_resp(conn, 400, "Bad Request")
  end

  defp create_code(conn, coupon_id, redemption_id, payload) do
    metadata =
      %{
        "yc_redemption_id" => redemption_id,
        "yc_deal_id" => payload["deal_id"],
        "yc_user_id" => payload["user_id"],
        "yc_company_id" => payload["company_id"],
        "yc_email" => payload["email"]
      }
      |> Map.reject(fn {_key, value} -> is_nil(value) end)

    case Billing.create_promotion_code(
           coupon_id,
           metadata,
           "yc-deal-#{payload["deal_id"]}-#{redemption_id}"
         ) do
      {:ok, code} ->
        Logger.info("Created YC deal promotion code", yc_redemption_id: redemption_id)
        sign_up_url = PortalWeb.Endpoint.url() <> "/sign_up"
        emailed? = send_code(payload, code, sign_up_url)

        json(conn, %{message: success_message(code, sign_up_url, emailed?)})

      {:error, reason} ->
        Logger.error("Failed to create YC deal promotion code",
          yc_redemption_id: redemption_id,
          reason: inspect(reason)
        )

        conn
        |> put_status(502)
        |> json(%{
          message:
            "We couldn't create your Firezone code. Please try again, or email support@firezone.dev."
        })
    end
  end

  defp send_code(%{"email" => email} = payload, code, sign_up_url) when is_binary(email) do
    # YC retries reuse the same Stripe code, so the matching job dedupes them.
    email
    |> Mailer.YCDealEmail.promotion_code_email(payload["first_name"], code, sign_up_url)
    |> Mailer.enqueue(unique: [period: 86_400])
    |> case do
      {:ok, %Oban.Job{}} -> true
      {:ok, :suppressed} -> false
      {:error, _reason} -> false
    end
  end

  defp send_code(_payload, _code, _sign_up_url), do: false

  defp success_message(code, sign_up_url, emailed?) do
    "Your Firezone promo code is #{code}. Sign up at #{sign_up_url}, then enter the code " <>
      "under Settings → Account → Manage billing when you choose a paid plan." <>
      if(emailed?, do: " We also emailed it to you.", else: "")
  end

  @doc false
  def sign(secret, payload) do
    :crypto.mac(:hmac, :sha256, secret, payload)
    |> Base.encode16(case: :lower)
  end
end
