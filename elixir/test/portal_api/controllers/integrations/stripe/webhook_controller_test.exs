defmodule PortalAPI.Integrations.Stripe.WebhookControllerTest do
  use PortalAPI.ConnCase, async: true
  import PortalAPI.Integrations.Stripe.WebhookController

  import Portal.AccountFixtures

  alias Portal.Mocks.Stripe

  describe "handle_webhook/2" do
    test "returns error when payload is not signed", %{conn: conn} do
      conn = post(conn, "/integrations/stripe/webhooks", %{"message" => "Hello, world!"})
      assert response(conn, 400) == "Bad Request: missing signature header"
    end

    test "returns error when timestamp is missing from the signature header", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("stripe-signature", "v1=deadbeef")
        |> post("/integrations/stripe/webhooks", "bar")

      assert response(conn, 400) == "Bad Request: missing timestamp"
    end

    test "returns error when signatures are missing from the signature header", %{conn: conn} do
      now = System.system_time(:second)

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("stripe-signature", "t=#{now}")
        |> post("/integrations/stripe/webhooks", "bar")

      assert response(conn, 400) == "Bad Request: missing signatures"
    end

    test "returns error when signature is invalid", %{conn: conn} do
      now = System.system_time(:second)
      signature = generate_signature(now, "foo")

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("stripe-signature", create_signature_header(now, signature))
        |> post("/integrations/stripe/webhooks", "bar")

      assert response(conn, 400) == "Bad Request: invalid signature"
    end

    test "ignores unrecognized segments in the signature header", %{conn: conn} do
      now = System.system_time(:second)
      signature = generate_signature(now, "foo")

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("stripe-signature", "t=#{now},foo=bar,v1=#{signature}")
        |> post("/integrations/stripe/webhooks", "bar")

      assert response(conn, 400) == "Bad Request: invalid signature"
    end

    test "returns 200 OK with the request body", %{conn: conn} do
      customer_id = "cus_xxx"
      account = account_fixture()

      account =
        account
        |> Ecto.Changeset.change()
        |> Ecto.Changeset.put_change(:metadata, %{stripe: %{customer_id: customer_id}})
        |> Portal.Repo.update!()

      # Build product with team metadata (subscription_object uses prod_test_team by default)
      product =
        Stripe.build_product(id: "prod_test_team", name: "Team", metadata: Stripe.team_metadata())

      expectations =
        Stripe.mock_fetch_customer_endpoint(account) ++
          Stripe.fetch_product_endpoint(product)

      Stripe.stub(expectations)

      payload =
        Stripe.build_event(
          "customer.subscription.updated",
          Stripe.subscription_object(customer_id, %{}, %{}, 0)
        )
        |> JSON.encode!()

      signed_at = System.system_time(:second) - 15
      signature = generate_signature(signed_at, payload)
      signature_header = create_signature_header(signed_at, signature)

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("stripe-signature", signature_header)
        |> post("/integrations/stripe/webhooks", payload)

      assert response(conn, 200) == ""
    end

    test "returns error with the signature is too old", %{conn: conn} do
      payload =
        Stripe.build_event(
          "customer.subscription.updated",
          Stripe.subscription_object("cus_xxx", %{}, %{}, 0)
        )
        |> JSON.encode!()

      signed_at = System.system_time(:second) - 301
      signature = generate_signature(signed_at, payload)
      signature_header = create_signature_header(signed_at, signature)

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("stripe-signature", signature_header)
        |> post("/integrations/stripe/webhooks", payload)

      assert response(conn, 400) == "Bad Request: expired signature"
    end

    test "warns when the signature is invalid", %{conn: conn} do
      now = System.system_time(:second)
      signature = generate_signature(now, "foo")

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          conn =
            conn
            |> put_req_header("content-type", "application/json")
            |> put_req_header("stripe-signature", create_signature_header(now, signature))
            |> post("/integrations/stripe/webhooks", "bar")

          assert response(conn, 400) == "Bad Request: invalid signature"
        end)

      assert log =~ "Stripe webhook failed authentication"
      assert log =~ "invalid_signature"
      assert log =~ "remote_ip=127.0.0.1"
    end

    test "warns when the signature header is missing", %{conn: conn} do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          conn = post(conn, "/integrations/stripe/webhooks", %{"message" => "Hello, world!"})
          assert response(conn, 400) == "Bad Request: missing signature header"
        end)

      assert log =~ "Stripe webhook failed authentication"
      assert log =~ "missing_signature_header"
    end

    test "rejects repeated signature headers instead of crashing", %{conn: conn} do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          conn =
            conn
            |> put_req_header("content-type", "application/json")
            |> Map.update!(:req_headers, &[{"stripe-signature", "t=1,v1=a"}, {"stripe-signature", "t=1,v1=b"} | &1])
            |> post("/integrations/stripe/webhooks", "bar")

          assert response(conn, 400) == "Bad Request: invalid signature header"
        end)

      assert log =~ "multiple_signature_headers"
    end

    test "rejects a non-numeric timestamp instead of crashing", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("stripe-signature", "t=abc,v1=deadbeef")
        |> post("/integrations/stripe/webhooks", "bar")

      assert response(conn, 400) == "Bad Request: missing timestamp"
    end

    test "rejects a timestamp from the future", %{conn: conn} do
      signed_at = System.system_time(:second) + 301
      signature = generate_signature(signed_at, "bar")

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("stripe-signature", create_signature_header(signed_at, signature))
        |> post("/integrations/stripe/webhooks", "bar")

      assert response(conn, 400) == "Bad Request: expired signature"
    end

    test "returns 500 when event handling fails so Stripe will retry", %{conn: conn} do
      customer_id = "cus_xxx"
      account = account_fixture()

      account =
        account
        |> Ecto.Changeset.change()
        |> Ecto.Changeset.put_change(:metadata, %{stripe: %{customer_id: customer_id}})
        |> Portal.Repo.update!()

      # Only stub customer endpoint, NOT the product endpoint
      # This will cause handle_events to fail when fetching the product
      Stripe.stub(Stripe.mock_fetch_customer_endpoint(account))

      payload =
        Stripe.build_event(
          "customer.subscription.updated",
          Stripe.subscription_object(customer_id, %{}, %{}, 0)
        )
        |> JSON.encode!()

      signed_at = System.system_time(:second) - 15
      signature = generate_signature(signed_at, payload)
      signature_header = create_signature_header(signed_at, signature)

      import ExUnit.CaptureLog

      {conn, _log} =
        with_log(fn ->
          conn
          |> put_req_header("content-type", "application/json")
          |> put_req_header("stripe-signature", signature_header)
          |> post("/integrations/stripe/webhooks", payload)
        end)

      assert response(conn, 500) == "Internal Error"
    end

    test "returns 200 OK for an account that does not exist so Stripe stops retrying", %{
      conn: conn
    } do
      customer_id = "cus_" <> Stripe.random_id()

      customer =
        Stripe.build_customer(id: customer_id, metadata: %{"account_id" => Ecto.UUID.generate()})

      Stripe.stub(Stripe.fetch_customer_endpoint(customer))

      payload =
        Stripe.build_event(
          "customer.subscription.deleted",
          Stripe.subscription_object(customer_id, %{}, %{}, 1)
        )
        |> JSON.encode!()

      signed_at = System.system_time(:second) - 15
      signature = generate_signature(signed_at, payload)

      {conn, log} =
        ExUnit.CaptureLog.with_log(fn ->
          conn
          |> put_req_header("content-type", "application/json")
          |> put_req_header("stripe-signature", create_signature_header(signed_at, signature))
          |> post("/integrations/stripe/webhooks", payload)
        end)

      assert response(conn, 200) == ""
      assert log =~ "Skipping stripe event for an account that does not exist"
    end
  end

  defp generate_signature(timestamp, payload) do
    secret = Portal.Billing.fetch_webhook_signing_secret!()
    sign(timestamp, secret, payload)
  end

  defp create_signature_header(timestamp, scheme \\ "v1", signature) do
    "t=#{timestamp},#{scheme}=#{signature}"
  end
end
