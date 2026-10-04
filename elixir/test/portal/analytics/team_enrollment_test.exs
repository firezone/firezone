defmodule Portal.Analytics.TeamEnrollmentTest do
  use Portal.DataCase, async: true
  use Oban.Testing, repo: Portal.Repo
  import Portal.AccountFixtures
  alias Portal.Analytics.{GoogleAds, OpenAI}
  alias Portal.Billing.EventHandler
  alias Portal.Mocks.Stripe

  setup do
    Portal.Config.put_env_override(:portal, OpenAI, api_key: "test-key")
    Portal.Config.put_env_override(:portal, GoogleAds,
      customer_id: "1234567890", subscription_conversion_action_id: "2222222222",
      service_account_email: "ads@example.com", workload_identity_provider: "provider",
      workload_identity_audience: "audience")
    account = account_fixture(metadata: %{
      stripe: %{customer_id: "cus_conversion", product_name: "Starter", billing_email: "ada@example.com"},
      marketing_attribution: %{"marketing_allowed" => true, "captured_at" => System.os_time(:second)}
    })
    customer = Stripe.build_customer(id: "cus_conversion", metadata: %{"account_id" => account.id})
    {product, _price, subscription} = Stripe.build_all(:team, "cus_conversion", 5)
    subscription = Map.merge(subscription, %{"status" => "active", "trial_end" => nil})
    Stripe.stub(Stripe.fetch_customer_endpoint(customer) ++ Stripe.fetch_product_endpoint(product))
    %{account: account, subscription: subscription}
  end

  test "confirmed Team upgrade queues once; webhook replay and seat changes do not", %{subscription: subscription} do
    event = Stripe.build_event("customer.subscription.updated", subscription)
    assert {:ok, ^event} = EventHandler.handle_event(event)
    assert [%{args: %{"event" => conversion}}] = all_enqueued(worker: OpenAI)
    assert conversion["type"] == "subscription_created"
    assert {:ok, ^event} = EventHandler.handle_event(event)
    later = Stripe.build_event("customer.subscription.updated", subscription, event["created"] + 1)
    assert {:ok, ^later} = EventHandler.handle_event(later)
    assert [_] = all_enqueued(worker: OpenAI)
    assert [_] = all_enqueued(worker: GoogleAds)
  end

  test "trial and incomplete subscriptions count only when they become active", %{subscription: subscription} do
    trial = Map.merge(subscription, %{"status" => "trialing", "trial_end" => System.os_time(:second) + 1000})
    event = Stripe.build_event("customer.subscription.created", trial)
    assert {:ok, _} = EventHandler.handle_event(event)
    assert [] = all_enqueued(worker: OpenAI)
    assert [] = all_enqueued(worker: GoogleAds)
    active = Stripe.build_event("customer.subscription.updated", subscription, event["created"] + 1)
    assert {:ok, _} = EventHandler.handle_event(active)
    assert [_] = all_enqueued(worker: OpenAI)
    assert [_] = all_enqueued(worker: GoogleAds)
  end

  test "incomplete Team enrollment waits for activation", %{subscription: subscription} do
    event = Stripe.build_event("customer.subscription.created", Map.put(subscription, "status", "incomplete"))
    assert {:ok, _} = EventHandler.handle_event(event)
    assert [] = all_enqueued(worker: OpenAI)
    assert [] = all_enqueued(worker: GoogleAds)
    active = Stripe.build_event("customer.subscription.updated", subscription, event["created"] + 1)
    assert {:ok, _} = EventHandler.handle_event(active)
    assert [_] = all_enqueued(worker: OpenAI)
    assert [_] = all_enqueued(worker: GoogleAds)
  end

  test "failed webhook transaction does not enqueue", %{subscription: subscription} do
    subscription = put_in(subscription, ["items", "data"], [])
    event = Stripe.build_event("customer.subscription.updated", subscription)
    assert {:error, :no_plan_product} = EventHandler.handle_event(event)
    assert [] = all_enqueued(worker: OpenAI)
    assert [] = all_enqueued(worker: GoogleAds)
  end
  test "enqueue failure rolls back billing and the processed marker so webhook replay recovers", %{subscription: subscription, account: account} do
    # Invalid UTF-8 cannot be encoded into an Oban JSON payload.
    Portal.Config.merge_env_override(:portal, GoogleAds, customer_id: <<255>>)
    event = Stripe.build_event("customer.subscription.updated", subscription)
    assert {:error, :conversion_enqueue_failed} = EventHandler.handle_event(event)
    refute Portal.Billing.Stripe.ProcessedEvents.event_processed?(event["id"])
    assert Portal.Billing.plan_type(Portal.Repo.get!(Portal.Account, account.id)) == :starter
    assert [] = all_enqueued(worker: OpenAI)
    assert [] = all_enqueued(worker: GoogleAds)

    Portal.Config.merge_env_override(:portal, GoogleAds, customer_id: "1234567890")
    assert {:ok, ^event} = EventHandler.handle_event(event)
    assert Portal.Billing.Stripe.ProcessedEvents.event_processed?(event["id"])
    assert [_] = all_enqueued(worker: OpenAI)
    assert [_] = all_enqueued(worker: GoogleAds)
  end

end
