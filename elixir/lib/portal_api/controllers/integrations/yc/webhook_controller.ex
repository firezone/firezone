defmodule PortalAPI.Integrations.YC.WebhookController do
  use PortalAPI, :controller
  alias Portal.Billing
  alias Portal.Mailer
  require Logger

  # From Bookface. The alumni deal is 23974.
  @current_batch_deal_id 2417

  @season_quarters %{
    "Winter" => 1,
    "W" => 1,
    "Spring" => 2,
    "Sp" => 2,
    "X" => 2,
    "Summer" => 3,
    "S" => 3,
    "Fall" => 4,
    "F" => 4
  }

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
      redeem(conn, payload, %{secret: secret, body: body, signature: signature})
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

  defp redeem(conn, %{"id" => redemption_id, "deal_id" => @current_batch_deal_id} = payload, request)
       when is_integer(redemption_id) do
    if current_batch?(payload) do
      redeem_deal(conn, @current_batch_deal_id, redemption_id, payload, request)
    else
      Logger.info("YC current batch deal redeemed by a founder outside the current batch",
        yc_redemption_id: redemption_id,
        batches: inspect(batches(payload))
      )

      conn
      |> put_status(422)
      |> json(%{
        message: "Oops! It looks like the batch has ended. Please use the alumni deal instead."
      })
    end
  end

  defp redeem(conn, %{"id" => redemption_id, "deal_id" => deal_id} = payload, request)
       when is_integer(redemption_id) do
    redeem_deal(conn, deal_id, redemption_id, payload, request)
  end

  defp redeem(conn, _payload, _request) do
    send_resp(conn, 400, "Bad Request")
  end

  defp redeem_deal(conn, deal_id, redemption_id, payload, request) do
    case Map.fetch(Portal.Config.fetch_env!(:portal, :yc_deal_coupon_ids), to_string(deal_id)) do
      {:ok, coupon_id} ->
        create_code(conn, coupon_id, redemption_id, payload, request)

      :error ->
        Logger.error("YC deal webhook for an unknown deal", yc_deal_id: deal_id)

        conn
        |> put_status(422)
        |> json(%{message: "This deal isn't set up yet. Please email support@firezone.dev."})
    end
  end

  # A batch counts as current until the end of its calendar quarter, which is
  # a few weeks after its Demo Day. Batches that have not started count too.
  defp current_batch?(payload) do
    today = payload |> redeemed_at() |> DateTime.to_date()

    payload
    |> batches()
    |> Enum.any?(fn batch ->
      case batch_ends_on(batch) do
        {:ok, ends_on} -> Date.compare(today, ends_on) != :gt
        :error -> false
      end
    end)
  end

  defp batches(%{"companies" => companies}) when is_list(companies) do
    for %{"batch" => batch} when is_binary(batch) <- companies, do: batch
  end

  defp batches(_payload), do: []

  # YC writes batches as "W26" or "Winter 2026". Spring is "X26" or "Sp26".
  defp batch_ends_on(batch) do
    case Regex.run(~r/^(Winter|Spring|Summer|Fall|Sp|W|X|S|F) ?(\d{4}|\d{2})$/, String.trim(batch)) do
      [_batch, season, year] ->
        year = String.to_integer(year)
        year = if year < 100, do: 2000 + year, else: year
        {:ok, Date.new!(year, Map.fetch!(@season_quarters, season) * 3, 1) |> Date.end_of_month()}

      nil ->
        :error
    end
  end

  defp create_code(conn, coupon_id, redemption_id, payload, request) do
    metadata =
      %{
        "yc_redemption_id" => redemption_id,
        "yc_deal_id" => payload["deal_id"],
        "yc_user_id" => payload["user_id"],
        "yc_company_id" => payload["company_id"],
        "yc_email" => payload["email"]
      }
      |> Map.reject(fn {_key, value} -> is_nil(value) end)

    expires_at = expires_at(payload)

    case Billing.create_promotion_code(
           promotion_code(request.secret, redemption_id),
           coupon_id,
           metadata,
           expires_at,
           "yc-deal-#{payload["deal_id"]}-#{redemption_id}"
         ) do
      {:ok, code} ->
        Logger.info("Created YC deal promotion code", yc_redemption_id: redemption_id)
        sign_up_url = PortalWeb.Endpoint.url() <> "/sign_up"
        expires_on = Calendar.strftime(expires_at, "%B %-d, %Y")
        conn = fetch_query_params(conn)

        # A mirrored redemption was already emailed and mirrored by the
        # portal that YC sent it to.
        emailed? =
          if conn.query_params["skip_email"] == "true" do
            false
          else
            mirror(request)
            send_code(payload, code, sign_up_url, expires_on)
          end

        json(conn, %{message: success_message(code, sign_up_url, expires_on, emailed?)})

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

  # Derived from the signed body, so every region creates the same code and a
  # YC retry gets the code it was given before.
  defp promotion_code(secret, redemption_id) do
    mac = :crypto.mac(:hmac, :sha256, secret, "promotion-code:#{redemption_id}")
    "YC" <> binary_part(Base.encode32(mac, padding: false), 0, 10)
  end

  defp mirror(%{body: body, signature: signature}) do
    if Portal.Config.fetch_env!(:portal, :yc_deal_mirror_url) not in [nil, ""] do
      %{"body" => body, "signature" => signature}
      |> Portal.Workers.MirrorYCDealRedemption.new()
      |> Oban.insert()
      |> case do
        {:ok, _job} ->
          :ok

        {:error, reason} ->
          Logger.error("Failed to enqueue YC deal redemption mirror", reason: inspect(reason))
      end
    end
  end

  # Codes work for 30 days from redemption. The expiry comes from the payload
  # rather than the clock so that a YC retry sends Stripe the same request.
  defp expires_at(payload) do
    payload
    |> redeemed_at()
    |> DateTime.truncate(:second)
    |> DateTime.shift(day: 30)
  end

  defp redeemed_at(payload) do
    case DateTime.from_iso8601(payload["redeemed_at"] || "") do
      {:ok, redeemed_at, _offset} -> redeemed_at
      {:error, _reason} -> DateTime.utc_now() |> DateTime.to_date() |> DateTime.new!(~T[00:00:00])
    end
  end

  defp send_code(%{"email" => email} = payload, code, sign_up_url, expires_on)
       when is_binary(email) do
    # YC retries reuse the same Stripe code, so the matching job dedupes them.
    email
    |> Mailer.YCDealEmail.promotion_code_email(
      payload["first_name"],
      code,
      sign_up_url,
      expires_on
    )
    |> Mailer.enqueue(unique: [period: 86_400])
    |> case do
      {:ok, %Oban.Job{}} -> true
      {:ok, :suppressed} -> false
      {:error, _reason} -> false
    end
  end

  defp send_code(_payload, _code, _sign_up_url, _expires_on), do: false

  defp success_message(code, sign_up_url, expires_on, emailed?) do
    "Your Firezone promo code is #{code}. Sign up at #{sign_up_url}, then enter the code " <>
      "under Settings → Account → Manage billing when you choose a paid plan. " <>
      "The code expires on #{expires_on}." <>
      if(emailed?, do: " We also emailed it to you.", else: "")
  end

  @doc false
  def sign(secret, payload) do
    :crypto.mac(:hmac, :sha256, secret, payload)
    |> Base.encode16(case: :lower)
  end
end
