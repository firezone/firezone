defmodule PortalAPI.Integrations.Stripe.WebhookControllerTest do
  use PortalAPI.ConnCase, async: true
  import PortalAPI.Integrations.Stripe.WebhookController

  import Portal.AccountFixtures

  describe "handle_webhook/2" do
    test "returns error when payload is not signed", %{conn: conn} do
      conn = post(conn, "/integrations/stripe/webhooks", %{"message" => "Hello, world!"})
      assert response(conn, 400) == "Bad Request: missing signature header"
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

    test "returns 200 OK with the request body", %{conn: conn} do
      customer_id = "cus_xxx"
      account = account_fixture()

      account =
        account
        |> Ecto.Changeset.change()
        |> Ecto.Changeset.put_change(:metadata, %{stripe: %{customer_id: customer_id}})
        |> Portal.Repo.update!()

      Bypass.open()
      |> Mocks.Stripe.mock_fetch_customer_endpoint(account)
      |> Mocks.Stripe.mock_fetch_product_endpoint("prod_Na6dGcTsmU0I4R")

      payload =
        Mocks.Stripe.build_event(
          "customer.subscription.updated",
          Mocks.Stripe.subscription_object(customer_id, %{}, %{}, 0)
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
        Mocks.Stripe.build_event(
          "customer.subscription.updated",
          Mocks.Stripe.subscription_object("cus_xxx", %{}, %{}, 0)
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
  end

  defp generate_signature(timestamp, payload) do
    secret = Portal.Billing.fetch_webhook_signing_secret!()
    sign(timestamp, secret, payload)
  end

  defp create_signature_header(timestamp, scheme \\ "v1", signature) do
    "t=#{timestamp},#{scheme}=#{signature}"
  end
end
