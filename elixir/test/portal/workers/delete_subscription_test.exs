defmodule Portal.Workers.DeleteSubscriptionTest do
  use Portal.DataCase, async: true
  use Oban.Testing, repo: Portal.Repo

  alias Portal.Workers.DeleteSubscription
  alias Portal.Mocks.Stripe

  describe "perform/1" do
    test "cancels Stripe subscriptions for customer" do
      subscription_id = "sub_#{System.unique_integer([:positive])}"
      customer_id = "cus_#{System.unique_integer([:positive])}"

      Stripe.stub(
        Stripe.mock_fetch_customer_subscriptions_endpoint(customer_id, [
          %{"id" => subscription_id, "object" => "subscription"}
        ]) ++
          Stripe.mock_cancel_subscription_endpoint(subscription_id)
      )

      assert :ok = perform_job(DeleteSubscription, %{"customer_id" => customer_id})
    end

    test "succeeds when subscriptions already cancelled (idempotent)" do
      subscription_id = "sub_#{System.unique_integer([:positive])}"
      customer_id = "cus_#{System.unique_integer([:positive])}"

      Stripe.stub(
        Stripe.mock_fetch_customer_subscriptions_endpoint(customer_id, [
          %{"id" => subscription_id, "object" => "subscription"}
        ]) ++
          Stripe.mock_cancel_subscription_endpoint(subscription_id, 404, %{})
      )

      assert :ok = perform_job(DeleteSubscription, %{"customer_id" => customer_id})
    end

    test "fails the job when Stripe returns 500 (triggers retry)" do
      subscription_id = "sub_#{System.unique_integer([:positive])}"
      customer_id = "cus_#{System.unique_integer([:positive])}"

      Stripe.stub(
        Stripe.mock_fetch_customer_subscriptions_endpoint(customer_id, [
          %{"id" => subscription_id, "object" => "subscription"}
        ]) ++
          Stripe.mock_cancel_subscription_endpoint(subscription_id, 500, %{})
      )

      assert {:error, _} = perform_job(DeleteSubscription, %{"customer_id" => customer_id})
    end

    test "cancels subscriptions in every status that is not canceled" do
      customer_id = "cus_#{System.unique_integer([:positive])}"

      stub_stripe(%{
        subscriptions: [
          %{"id" => "sub_trialing", "status" => "trialing"},
          %{"id" => "sub_active", "status" => "active"},
          %{"id" => "sub_paused", "status" => "paused"},
          %{"id" => "sub_expired", "status" => "incomplete_expired"}
        ]
      })

      assert :ok = perform_job(DeleteSubscription, %{"customer_id" => customer_id})

      assert_received {:stripe_request, "GET", "/v1/subscriptions", query, _body}
      refute query =~ "status="
      assert_received {:stripe_request, "DELETE", "/v1/subscriptions/sub_trialing", _, _}
      assert_received {:stripe_request, "DELETE", "/v1/subscriptions/sub_active", _, _}
      assert_received {:stripe_request, "DELETE", "/v1/subscriptions/sub_paused", _, _}
      refute_received {:stripe_request, "DELETE", "/v1/subscriptions/sub_expired", _, _}
      refute_received {:stripe_request, "GET", "/v1/invoices", _, _}
    end

    test "keeps collecting open invoices of past due and unpaid subscriptions" do
      customer_id = "cus_#{System.unique_integer([:positive])}"

      stub_stripe(%{
        subscriptions: [
          %{"id" => "sub_past_due", "status" => "past_due"},
          %{"id" => "sub_unpaid", "status" => "unpaid"}
        ],
        invoices: %{
          "sub_past_due" => [%{"id" => "in_past_due"}],
          "sub_unpaid" => [%{"id" => "in_unpaid"}]
        }
      })

      assert :ok = perform_job(DeleteSubscription, %{"customer_id" => customer_id})

      assert_received {:stripe_request, "DELETE", "/v1/subscriptions/sub_past_due", _, _}
      assert_received {:stripe_request, "GET", "/v1/invoices", query, _}
      assert query =~ "subscription=sub_past_due"
      assert query =~ "status=open"
      assert_received {:stripe_request, "POST", "/v1/invoices/in_past_due", _, "auto_advance=true"}
      assert_received {:stripe_request, "DELETE", "/v1/subscriptions/sub_unpaid", _, _}
      assert_received {:stripe_request, "POST", "/v1/invoices/in_unpaid", _, "auto_advance=true"}
    end

    test "fails the job when collection of open invoices cannot be resumed" do
      customer_id = "cus_#{System.unique_integer([:positive])}"

      stub_stripe(%{
        subscriptions: [%{"id" => "sub_past_due", "status" => "past_due"}],
        invoices: %{"sub_past_due" => [%{"id" => "in_past_due"}]},
        invoice_update_status: 500
      })

      assert {:error, _} = perform_job(DeleteSubscription, %{"customer_id" => customer_id})
    end

    test "is a no-op when billing disabled" do
      Portal.Config.put_env_override(Portal.Billing, enabled: false)

      customer_id = "cus_#{System.unique_integer([:positive])}"

      assert :ok = perform_job(DeleteSubscription, %{"customer_id" => customer_id})
    end
  end

  defp stub_stripe(opts) do
    test_pid = self()
    invoices = Map.get(opts, :invoices, %{})

    Req.Test.stub(Portal.Billing.Stripe.APIClient, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:stripe_request, conn.method, conn.request_path, conn.query_string, body})

      {status, response} =
        case {conn.method, conn.path_info} do
          {"GET", ["v1", "subscriptions"]} ->
            {200, %{"object" => "list", "data" => opts.subscriptions, "has_more" => false}}

          {"DELETE", ["v1", "subscriptions", id]} ->
            {200, %{"id" => id, "object" => "subscription", "status" => "canceled"}}

          {"GET", ["v1", "invoices"]} ->
            id = conn |> Plug.Conn.fetch_query_params() |> Map.get(:query_params) |> Map.get("subscription")
            {200, %{"object" => "list", "data" => Map.get(invoices, id, []), "has_more" => false}}

          {"POST", ["v1", "invoices", id]} ->
            {Map.get(opts, :invoice_update_status, 200), %{"id" => id, "object" => "invoice"}}
        end

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(status, JSON.encode!(response))
    end)
  end
end
