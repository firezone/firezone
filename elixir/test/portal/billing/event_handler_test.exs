defmodule Portal.Billing.EventHandlerTest do
  use Portal.DataCase, async: true

  alias Portal.Billing.EventHandler
  alias Portal.Mocks.Stripe

  import Portal.AccountFixtures

  describe "handle_event/1 with customer.updated" do
    setup do
      account =
        account_fixture(%{
          metadata: %{
            stripe: %{
              customer_id: "cus_existing123"
            }
          }
        })

      %{account: account}
    end

    test "updates account with legal_name from customer name", %{account: account} do
      customer =
        Stripe.build_customer(
          id: account.metadata.stripe.customer_id,
          name: "Updated Legal Name",
          email: "updated@example.com",
          metadata: %{
            "account_id" => account.id
          }
        )

      event = Stripe.build_event("customer.updated", customer)

      # Mock the fetch customer endpoint (called to get account_id from metadata)
      Stripe.stub(Stripe.fetch_customer_endpoint(customer))

      assert {:ok, _event} = EventHandler.handle_event(event)

      updated_account = Portal.Repo.get!(Portal.Account, account.id)
      assert updated_account.legal_name == "Updated Legal Name"
    end

    test "uses account_name from metadata for name but legal_name from customer name", %{
      account: account
    } do
      customer =
        Stripe.build_customer(
          id: account.metadata.stripe.customer_id,
          name: "Legal Corp Inc",
          email: "updated@example.com",
          metadata: %{
            "account_id" => account.id,
            "account_name" => "Friendly Display Name"
          }
        )

      event = Stripe.build_event("customer.updated", customer)

      # Mock the fetch customer endpoint (called to get account_id from metadata)
      Stripe.stub(Stripe.fetch_customer_endpoint(customer))

      assert {:ok, _event} = EventHandler.handle_event(event)

      updated_account = Portal.Repo.get!(Portal.Account, account.id)
      assert updated_account.name == "Friendly Display Name"
      assert updated_account.legal_name == "Legal Corp Inc"
    end

    test "updates account slug from metadata", %{account: account} do
      original_slug = account.slug

      customer =
        Stripe.build_customer(
          id: account.metadata.stripe.customer_id,
          name: "Same Name",
          email: "updated@example.com",
          metadata: %{
            "account_id" => account.id,
            "account_slug" => "new-custom-slug"
          }
        )

      event = Stripe.build_event("customer.updated", customer)

      Stripe.stub(Stripe.fetch_customer_endpoint(customer))

      assert {:ok, _event} = EventHandler.handle_event(event)

      updated_account = Portal.Repo.get!(Portal.Account, account.id)
      assert updated_account.slug == "new-custom-slug"
      assert updated_account.slug != original_slug
    end
  end

  describe "handle_event/1 with customer.subscription.deleted" do
    setup do
      account =
        account_fixture(%{
          metadata: %{
            stripe: %{
              customer_id: "cus_existing123"
            }
          }
        })

      %{account: account}
    end

    test "disables account when subscription is deleted", %{account: account} do
      subscription = Stripe.subscription_object(account.metadata.stripe.customer_id, %{}, %{}, 1)
      subscription = Map.put(subscription, "status", "canceled")

      event = Stripe.build_event("customer.subscription.deleted", subscription)

      customer =
        Stripe.build_customer(
          id: account.metadata.stripe.customer_id,
          metadata: %{"account_id" => account.id}
        )

      Stripe.stub(Stripe.fetch_customer_endpoint(customer))

      assert {:ok, _event} = EventHandler.handle_event(event)

      updated_account = Portal.Repo.get!(Portal.Account, account.id)
      assert updated_account.disabled_at != nil
      assert updated_account.disabled_reason == "Stripe subscription deleted"
    end
  end

  describe "handle_event/1 with customer.created" do
    test "returns error when required metadata is missing" do
      customer_id = "cus_" <> Stripe.random_id()

      customer =
        Stripe.build_customer(
          id: customer_id,
          name: "Incomplete Corp",
          email: "admin@incomplete.com",
          metadata: %{}
        )

      event = Stripe.build_event("customer.created", customer)

      assert {:error, :missing_custom_metadata} = EventHandler.handle_event(event)
    end

    test "skips account creation when account_id already in metadata" do
      customer_id = "cus_" <> Stripe.random_id()
      existing_account_id = Ecto.UUID.generate()

      customer =
        Stripe.build_customer(
          id: customer_id,
          name: "Existing Corp",
          email: "admin@existing.com",
          metadata: %{
            "account_id" => existing_account_id,
            "company_website" => "existing.com",
            "account_owner_first_name" => "Test",
            "account_owner_last_name" => "User"
          }
        )

      event = Stripe.build_event("customer.created", customer)

      assert {:ok, _event} = EventHandler.handle_event(event)

      # No account should be created
      account = Portal.Repo.get_by(Portal.Account, slug: "existing")
      assert account == nil
    end

    test "creates account with all defaults when metadata is complete" do
      customer_id = "cus_" <> Stripe.random_id()

      customer =
        Stripe.build_customer(
          id: customer_id,
          name: "New Corp Inc",
          email: "billing@newcorp.com",
          metadata: %{
            "company_website" => "https://newcorp.com",
            "account_owner_first_name" => "Jane",
            "account_owner_last_name" => "Doe"
          }
        )

      event = Stripe.build_event("customer.created", customer)

      # Mock the update customer endpoint (called to set account_id in Stripe metadata)
      # and the create subscription endpoint
      expectations =
        [{"POST", "/v1/customers/#{customer_id}", 200, customer}] ++
          Stripe.mock_create_subscription_endpoint()

      Stripe.stub(expectations)

      assert {:ok, _event} = EventHandler.handle_event(event)

      # Account should be created
      account = Portal.Repo.get_by(Portal.Account, slug: "newcorp")
      assert account != nil
      assert account.name == "New Corp Inc"
      assert account.legal_name == "New Corp Inc"

      # Email OTP provider should be created
      email_provider = Portal.Repo.get_by(Portal.EmailOTP.AuthProvider, account_id: account.id)
      assert email_provider != nil
      assert email_provider.name == "Email (OTP)"

      # Admin actor should be created
      admin = Portal.Repo.get_by(Portal.Actor, account_id: account.id, type: :account_admin_user)
      assert admin != nil
      assert admin.email == "billing@newcorp.com"
      assert admin.name == "Jane Doe"
    end
  end
end
