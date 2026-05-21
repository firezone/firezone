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

    test "is a no-op when billing disabled" do
      Portal.Config.put_env_override(Portal.Billing, enabled: false)

      customer_id = "cus_#{System.unique_integer([:positive])}"

      assert :ok = perform_job(DeleteSubscription, %{"customer_id" => customer_id})
    end
  end
end
