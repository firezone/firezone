defmodule Domain.BillingTest do
  use Domain.DataCase, async: true
  import Domain.Billing
  alias Domain.Billing
  alias Domain.Mocks.Stripe

  setup do
    account = Fixtures.Accounts.create_account()
    actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
    identity = Fixtures.Auth.create_identity(account: account, actor: actor)
    subject = Fixtures.Auth.create_subject(identity: identity)

    %{
      account: account,
      actor: actor,
      identity: identity,
      subject: subject
    }
  end

  describe "provision_account/1" do
    test "returns account if billing is disabled", %{account: account} do
      Domain.Config.put_env_override(Domain.Billing,
        secret_key: nil,
        default_price_id: nil,
        enabled: false
      )

      assert provision_account(account) == {:ok, account}
    end

    test "creates a customer and persists it's ID in the account", %{account: account} do
      Bypass.open()
      |> Stripe.mock_create_customer_endpoint(account)
      |> Stripe.mock_create_subscription_endpoint()

      assert {:ok, account} = provision_account(account)
      assert account.metadata.stripe.customer_id == "cus_NffrFeUfNV2Hib"
      assert account.metadata.stripe.subscription_id == "sub_1MowQVLkdIwHu7ixeRlqHVzs"

      assert_receive {:bypass_request, %{request_path: "/v1/customers"} = conn}
      assert conn.params == %{"name" => account.name, "metadata" => %{"account_id" => account.id}}
    end

    test "returns error when Stripe API call fails", %{account: account} do
      bypass = Bypass.open()
      Stripe.override_endpoint_url("http://localhost:#{bypass.port}")
      Bypass.down(bypass)

      assert provision_account(account) == {:error, :retry_later}
    end
  end

  describe "billing_portal_url/3" do
    test "returns valid billing portal url", %{account: account, subject: subject} do
      bypass =
        Bypass.open()
        |> Stripe.mock_create_customer_endpoint(account)
        |> Stripe.mock_create_subscription_endpoint()

      assert {:ok, account} = provision_account(account)

      Stripe.mock_create_billing_session_endpoint(bypass, account)
      assert {:ok, url} = billing_portal_url(account, "https://example.com/account", subject)
      assert url =~ "billing.stripe.com"

      assert_receive {:bypass_request, %{request_path: "/v1/billing_portal/sessions"} = conn}

      assert conn.params == %{
               "customer" => account.metadata.stripe.customer_id,
               "return_url" => "https://example.com/account"
             }
    end

    test "returns error when subject has no permission to manage account billing", %{
      account: account,
      subject: subject
    } do
      subject = Fixtures.Auth.remove_permissions(subject)

      assert billing_portal_url(account, "https://example.com/account", subject) ==
               {:error,
                {:unauthorized,
                 reason: :missing_permissions,
                 missing_permissions: [Billing.Authorizer.manage_own_account_billing_permission()]}}
    end
  end

  describe "handle_events/1" do
    setup %{account: account} do
      customer_id = "cus_" <> Ecto.UUID.generate()

      {:ok, account} =
        Domain.Accounts.update_account(account, %{
          metadata: %{stripe: %{customer_id: customer_id}},
          features: %{
            flow_activities: nil,
            multi_site_resources: nil,
            traffic_filters: nil,
            self_hosted_relays: nil,
            idp_sync: nil
          },
          limits: %{
            monthly_active_users_count: nil
          }
        })

      %{account: account, customer_id: customer_id}
    end

    test "disables the account on when subscription is deleted", %{
      account: account,
      customer_id: customer_id
    } do
      Bypass.open() |> Stripe.mock_fetch_customer_endpoint(account)

      event =
        Stripe.build_event(
          "customer.subscription.deleted",
          Stripe.subscription_object(customer_id, %{}, %{}, 0)
        )

      assert handle_events([event]) == :ok

      assert account = Repo.get(Domain.Accounts.Account, account.id)
      assert not is_nil(account.disabled_at)
      assert account.disabled_reason == "Stripe subscription deleted"
    end

    test "disables the account on when subscription is paused (updated event)", %{
      account: account,
      customer_id: customer_id
    } do
      Bypass.open() |> Stripe.mock_fetch_customer_endpoint(account)

      event =
        Stripe.build_event(
          "customer.subscription.updated",
          Stripe.subscription_object(customer_id, %{}, %{}, 0)
          |> Map.put("pause_collection", %{"behavior" => "void"})
        )

      assert handle_events([event]) == :ok

      assert account = Repo.get(Domain.Accounts.Account, account.id)
      assert not is_nil(account.disabled_at)
      assert account.disabled_reason == "Stripe subscription paused"
    end

    test "re-enables the account on subscription update (paused event)", %{
      account: account,
      customer_id: customer_id
    } do
      Bypass.open()
      |> Stripe.mock_fetch_customer_endpoint(account)
      |> Stripe.mock_fetch_product_endpoint("prod_Na6dGcTsmU0I4R")

      {:ok, account} =
        Domain.Accounts.update_account(account, %{
          disabled_at: DateTime.utc_now(),
          disabled_reason: "Stripe subscription paused"
        })

      event =
        Stripe.build_event(
          "customer.subscription.updated",
          Stripe.subscription_object(customer_id, %{}, %{}, 0)
        )

      assert handle_events([event]) == :ok

      assert account = Repo.get(Domain.Accounts.Account, account.id)
      assert account.disabled_at == nil
      assert account.disabled_reason == nil
    end

    test "updates account features and limits on subscription update", %{
      account: account,
      customer_id: customer_id
    } do
      Bypass.open()
      |> Stripe.mock_fetch_customer_endpoint(account)
      |> Stripe.mock_fetch_product_endpoint("prod_Na6dGcTsmU0I4R", %{
        metadata: %{
          "multi_site_resources" => "false",
          "self_hosted_relays" => "true",
          "monthly_active_users_count" => "15",
          "sites_count" => 1
        }
      })

      subscription_metadata = %{
        "idp_sync" => "true",
        "multi_site_resources" => "true",
        "traffic_filters" => "false",
        "sites_count" => 5
      }

      quantity = 13

      event =
        Stripe.build_event(
          "customer.subscription.updated",
          Stripe.subscription_object(customer_id, subscription_metadata, %{}, quantity)
        )

      assert handle_events([event]) == :ok

      assert account = Repo.get(Domain.Accounts.Account, account.id)

      assert account.metadata.stripe.customer_id == customer_id
      assert account.metadata.stripe.subscription_id
      assert account.metadata.stripe.product_name == "Enterprise"

      assert account.limits == %Domain.Accounts.Limits{
               monthly_active_users_count: 15,
               sites_count: 5
             }

      assert account.features == %Domain.Accounts.Features{
               flow_activities: nil,
               idp_sync: true,
               multi_site_resources: true,
               self_hosted_relays: true,
               traffic_filters: false
             }
    end
  end
end
