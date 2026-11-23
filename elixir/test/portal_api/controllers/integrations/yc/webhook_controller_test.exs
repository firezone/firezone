defmodule PortalAPI.Integrations.YC.WebhookControllerTest do
  use PortalAPI.ConnCase, async: true
  use Oban.Testing, repo: Portal.Repo

  alias Portal.Billing.Stripe.APIClient
  alias Portal.Workers.MirrorYCDealRedemption
  alias PortalAPI.Integrations.YC.WebhookController

  @secret "yc-secret"
  # Derived from @secret and the redemption ID of payload/1.
  @code "YCHDNTAFHVKN"
  @path "/integrations/yc/webhooks"

  setup do
    Portal.Config.put_env_override(:portal, :yc_deal_webhook_secrets, %{
      "2417" => @secret,
      "23974" => "alumni-secret",
      "1" => "unmapped-secret"
    })

    Portal.Config.put_env_override(:portal, :yc_deal_coupon_ids, %{"2417" => "coupon_yc"})
    :ok
  end

  describe "handle_webhook/2" do
    test "rejects requests without a signature", %{conn: conn} do
      conn = post_raw(conn, payload(), [])
      assert response(conn, 401) == "Unauthorized"
    end

    test "rejects requests with an invalid signature", %{conn: conn} do
      body = payload()
      conn = post_raw(conn, body, [{"x-yc-signature", WebhookController.sign("wrong", body)}])
      assert response(conn, 401) == "Unauthorized"
    end

    test "rejects requests signed with another deal's secret", %{conn: conn} do
      body = payload()

      conn =
        post_raw(conn, body, [{"x-yc-signature", WebhookController.sign("alumni-secret", body)}])

      assert response(conn, 401) == "Unauthorized"
    end

    test "rejects requests for a deal without a secret", %{conn: conn} do
      body = payload(%{"deal_id" => 2})
      conn = post_signed(conn, body)
      assert response(conn, 401) == "Unauthorized"
    end

    test "rejects payloads that are not JSON", %{conn: conn} do
      conn = post_signed(conn, "not json")
      assert response(conn, 400) == "Bad Request"
    end

    test "rejects payloads without a redemption id", %{conn: conn} do
      body = JSON.encode!(%{"deal_id" => 2417, "email" => "alice@example.com"})
      conn = post_signed(conn, body)
      assert response(conn, 400) == "Bad Request"
    end

    test "creates a single-use promotion code and emails it", %{conn: conn} do
      stub_stripe()

      conn = post_signed(conn, payload())

      assert %{"message" => message} = json_response(conn, 200)
      assert message =~ @code
      assert message =~ "The code expires on December 13, 2026."
      assert message =~ "We also emailed it to you."
      assert String.length(message) <= 500

      assert_receive {:stripe, "GET", "/v1/promotion_codes", lookup_conn, _params}
      assert URI.decode_query(lookup_conn.query_string)["code"] == @code

      assert_receive {:stripe, "POST", "/v1/promotion_codes", stripe_conn, params}
      assert Plug.Conn.get_req_header(stripe_conn, "idempotency-key") == ["yc-deal-2417-123456"]

      assert params == %{
               "code" => @code,
               "coupon" => "coupon_yc",
               "max_redemptions" => "1",
               "expires_at" => to_string(DateTime.to_unix(~U[2026-12-13 16:54:57Z])),
               "metadata[yc_redemption_id]" => "123456",
               "metadata[yc_deal_id]" => "2417",
               "metadata[yc_user_id]" => "24680",
               "metadata[yc_company_id]" => "67890",
               "metadata[yc_email]" => "alice@example.com"
             }

      assert [job] =
               [worker: Portal.Workers.OutboundEmail]
               |> Oban.Job.query()
               |> Repo.all()

      assert job.args["request"]["to"] == [%{"name" => "", "address" => "alice@example.com"}]
      assert job.args["request"]["subject"] == "Your Firezone YC deal code"
      assert job.args["request"]["text_body"] =~ "Hi Alice,"
      assert job.args["request"]["text_body"] =~ @code
      assert job.args["request"]["text_body"] =~ "expires on December 13, 2026"

      refute_enqueued(worker: MirrorYCDealRedemption)
    end

    test "returns the existing code without creating another", %{conn: conn} do
      stub_stripe(existing: [%{"id" => "promo_123", "code" => @code}])

      conn = post_signed(conn, payload())

      assert json_response(conn, 200)["message"] =~ @code
      refute_received {:stripe, "POST", "/v1/promotion_codes", _conn, _params}
    end

    test "sends the redemption to the other region's portal", %{conn: conn} do
      Portal.Config.put_env_override(:portal, :yc_deal_mirror_url, "https://eu.example.com/yc")
      stub_stripe()

      body = payload()
      conn = post_signed(conn, body)

      assert json_response(conn, 200)
      signature = WebhookController.sign(@secret, body)

      assert_enqueued(
        worker: MirrorYCDealRedemption,
        args: %{"body" => body, "signature" => signature}
      )
    end

    test "neither emails nor mirrors a mirrored redemption", %{conn: conn} do
      Portal.Config.put_env_override(:portal, :yc_deal_mirror_url, "https://eu.example.com/yc")
      stub_stripe()

      body = payload()

      conn =
        conn
        |> put_req_header("x-yc-signature", WebhookController.sign(@secret, body))
        |> put_req_header("content-type", "application/json")
        |> post(@path <> "?skip_email=true", body)

      assert %{"message" => message} = json_response(conn, 200)
      assert message =~ @code
      refute message =~ "emailed"

      assert [] == [worker: Portal.Workers.OutboundEmail] |> Oban.Job.query() |> Repo.all()
      refute_enqueued(worker: MirrorYCDealRedemption)
    end

    test "sends Stripe the same request when YC retries", %{conn: conn} do
      stub_stripe()

      body = payload()
      post_signed(conn, body)
      post_signed(build_conn(), body)

      assert_receive {:stripe, "POST", "/v1/promotion_codes", _conn, first}
      assert_receive {:stripe, "POST", "/v1/promotion_codes", _conn, ^first}
    end

    test "returns the code without emailing when the payload has no email", %{conn: conn} do
      stub_stripe()

      body = payload(%{"email" => nil})
      conn = post_signed(conn, body)

      assert %{"message" => message} = json_response(conn, 200)
      assert message =~ @code
      refute message =~ "emailed"

      assert [] == [worker: Portal.Workers.OutboundEmail] |> Oban.Job.query() |> Repo.all()
    end

    test "accepts the current batch deal until the end of the batch's quarter", %{conn: conn} do
      stub_stripe()

      body =
        payload(%{
          "companies" => [%{"batch" => "Summer 2026"}],
          "redeemed_at" => "2026-09-30T23:59:59Z"
        })

      assert json_response(post_signed(conn, body), 200)["message"] =~ @code
    end

    test "accepts the current batch deal when any company is in a current batch", %{conn: conn} do
      stub_stripe()

      body = payload(%{"companies" => [%{"batch" => "W24"}, %{"batch" => "X27"}]})

      assert json_response(post_signed(conn, body), 200)["message"] =~ @code
    end

    test "rejects the current batch deal after the batch's quarter ends", %{conn: conn} do
      for {batch, redeemed_at} <- [
            {"W26", "2026-04-01T00:00:00Z"},
            {"X26", "2026-07-01T00:00:00Z"},
            {"Sp26", "2026-07-01T00:00:00Z"},
            {"S26", "2026-10-01T00:00:00Z"},
            {"F25", "2026-01-01T00:00:00Z"}
          ] do
        body = payload(%{"companies" => [%{"batch" => batch}], "redeemed_at" => redeemed_at})

        assert json_response(post_signed(conn, body), 422) == %{
                 "message" =>
                   "Oops! It looks like the batch has ended. Please use the alumni deal instead."
               }
      end
    end

    test "rejects the current batch deal without a known batch", %{conn: conn} do
      for companies <- [[], [%{"batch" => nil}], [%{"batch" => "IK12"}], nil] do
        body = payload(%{"companies" => companies})

        assert json_response(post_signed(conn, body), 422)["message"] =~
                 "Please use the alumni deal instead."
      end
    end

    test "accepts the alumni deal from any batch", %{conn: conn} do
      Portal.Config.put_env_override(:portal, :yc_deal_coupon_ids, %{
        "2417" => "coupon_yc",
        "23974" => "coupon_alumni"
      })

      stub_stripe()

      body = payload(%{"deal_id" => 23_974, "companies" => [%{"batch" => "W24"}]})

      conn =
        post_raw(conn, body, [{"x-yc-signature", WebhookController.sign("alumni-secret", body)}])

      assert json_response(conn, 200)
      assert_receive {:stripe, "POST", "/v1/promotion_codes", _conn, %{"coupon" => "coupon_alumni"}}
    end

    test "rejects redemptions of a deal without a coupon", %{conn: conn} do
      body = payload(%{"deal_id" => 1})
      conn = post_raw(conn, body, [{"x-yc-signature", WebhookController.sign("unmapped-secret", body)}])

      assert %{"message" => message} = json_response(conn, 422)
      assert message =~ "support@firezone.dev"
    end

    test "rejects the redemption when Stripe fails", %{conn: conn} do
      Req.Test.stub(APIClient, fn conn ->
        conn
        |> Plug.Conn.put_status(400)
        |> Req.Test.json(%{"error" => %{"message" => "No such coupon"}})
      end)

      conn = post_signed(conn, payload())

      assert %{"message" => message} = json_response(conn, 502)
      assert message =~ "support@firezone.dev"
    end
  end

  defp stub_stripe(opts \\ []) do
    test_pid = self()

    Req.Test.stub(APIClient, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:stripe, conn.method, conn.request_path, conn, URI.decode_query(body)})

      case conn.method do
        "GET" -> Req.Test.json(conn, %{"data" => Keyword.get(opts, :existing, [])})
        "POST" -> Req.Test.json(conn, %{"id" => "promo_123", "code" => @code})
      end
    end)
  end

  defp post_signed(conn, body) do
    post_raw(conn, body, [{"x-yc-signature", WebhookController.sign(@secret, body)}])
  end

  defp post_raw(conn, body, headers) do
    headers
    |> Enum.reduce(conn, fn {key, value}, conn -> put_req_header(conn, key, value) end)
    |> put_req_header("content-type", "application/json")
    |> post(@path, body)
  end

  defp payload(overrides \\ %{}) do
    %{
      "id" => 123_456,
      "deal_id" => 2417,
      "company_id" => 67_890,
      "user_id" => 24_680,
      "first_name" => "Alice",
      "last_name" => "Whysee",
      "email" => "alice@example.com",
      "companies" => [%{"id" => 67_890, "name" => "Example", "batch" => "F26"}],
      "redeemed_at" => "2026-11-13T16:54:57.268Z",
      "custom_responses" => %{},
      "webhook_status" => nil
    }
    |> Map.merge(overrides)
    |> JSON.encode!()
  end
end
