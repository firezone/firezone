defmodule PortalAPI.Integrations.YC.WebhookControllerTest do
  use PortalAPI.ConnCase, async: true

  alias Portal.Billing.Stripe.APIClient
  alias PortalAPI.Integrations.YC.WebhookController

  @secret "yc-secret"
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
      test_pid = self()

      Req.Test.stub(APIClient, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:stripe, conn.method, conn.request_path, conn, URI.decode_query(body)})
        Req.Test.json(conn, %{"id" => "promo_123", "code" => "YC8K2F9Q"})
      end)

      conn = post_signed(conn, payload())

      assert %{"message" => message} = json_response(conn, 200)
      assert message =~ "YC8K2F9Q"
      assert message =~ "We also emailed it to you."

      assert_receive {:stripe, "POST", "/v1/promotion_codes", stripe_conn, params}
      assert Plug.Conn.get_req_header(stripe_conn, "idempotency-key") == ["yc-deal-2417-123456"]

      assert params == %{
               "coupon" => "coupon_yc",
               "max_redemptions" => "1",
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
      assert job.args["request"]["text_body"] =~ "YC8K2F9Q"
    end

    test "returns the code without emailing when the payload has no email", %{conn: conn} do
      Req.Test.stub(APIClient, &Req.Test.json(&1, %{"code" => "YC8K2F9Q"}))

      body = payload(%{"email" => nil})
      conn = post_signed(conn, body)

      assert %{"message" => message} = json_response(conn, 200)
      assert message =~ "YC8K2F9Q"
      refute message =~ "emailed"

      assert [] == [worker: Portal.Workers.OutboundEmail] |> Oban.Job.query() |> Repo.all()
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
      "companies" => [],
      "redeemed_at" => "2026-11-13T16:54:57.268Z",
      "custom_responses" => %{},
      "webhook_status" => nil
    }
    |> Map.merge(overrides)
    |> JSON.encode!()
  end
end
