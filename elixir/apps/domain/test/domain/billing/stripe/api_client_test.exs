defmodule Domain.Billing.Stripe.APIClientTest do
  use Domain.DataCase, async: true
  alias Domain.Mocks.Stripe
  import Domain.Billing.Stripe.APIClient

  describe "client retry logic" do
    test "retries on 429 rate limit responses" do
      bypass = Bypass.open()
      account = Fixtures.Accounts.create_account()

      # Configure to return 429 on first 2 requests, then succeed
      Stripe.enable_rate_limiting(2)
      Stripe.mock_create_customer_endpoint(bypass, account)

      # This should succeed after 2 retries
      {:ok, _customer} =
        create_customer("secret_token_123", account.name, "test@example.com", %{})

      # Verify 3 total requests were made (2 failures + 1 success)
      assert Stripe.get_request_count() == 3

      Domain.Mocks.Stripe.disable_rate_limiting()
    end

    test "gives up after max retries exceeded" do
      bypass = Bypass.open()
      account = Fixtures.Accounts.create_account()

      # Configure to always return 429
      Stripe.configure_rate_limiting(fn _count -> true end)
      Stripe.mock_create_customer_endpoint(bypass, account)

      # This should fail after exhausting retries
      {:error, {429, _}} =
        create_customer("secret_token_123", account.name, "test@example.com", %{})

      # Should have made max_retries + 1 attempts
      assert Stripe.get_request_count() == 4

      Domain.Mocks.Stripe.disable_rate_limiting()
    end
  end
end
