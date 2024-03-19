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

  describe "enabled?/0" do
    test "returns true when billing is enabled", %{} do
      assert enabled?() == true
    end

    test "returns false when billing is disabled", %{} do
      Domain.Config.put_env_override(Domain.Billing, enabled: false)
      assert enabled?() == false
    end
  end

  describe "account_provisioned?/1" do
    test "returns true when account is provisioned", %{account: account} do
      {:ok, account} =
        Domain.Accounts.update_account(account, %{
          metadata: %{stripe: %{customer_id: Ecto.UUID.generate()}}
        })

      assert account_provisioned?(account) == true
    end

    test "returns false when account is not provisioned", %{account: account} do
      assert account_provisioned?(account) == false
    end
  end

  describe "seats_limit_exceeded?/2" do
    test "returns false when seats limit is not exceeded", %{account: account} do
      {:ok, account} =
        Domain.Accounts.update_account(account, %{
          limits: %{monthly_active_users_count: 10}
        })

      assert seats_limit_exceeded?(account, 10) == false
    end

    test "returns true when seats limit is exceeded", %{account: account} do
      {:ok, account} =
        Domain.Accounts.update_account(account, %{
          limits: %{monthly_active_users_count: 10}
        })

      assert seats_limit_exceeded?(account, 11) == true
    end

    test "returns true when seats limit is not set", %{account: account} do
      assert seats_limit_exceeded?(account, 0) == false
    end
  end

  describe "can_create_users?/1" do
    test "returns true when seats limit is not exceeded", %{account: account} do
      {:ok, account} =
        Domain.Accounts.update_account(account, %{
          limits: %{monthly_active_users_count: 3}
        })

      actor1 = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
      Fixtures.Clients.create_client(account: account, actor: actor1)
      Fixtures.Clients.create_client(account: account, actor: actor1)

      actor2 = Fixtures.Actors.create_actor(type: :account_user, account: account)
      Fixtures.Clients.create_client(account: account, actor: actor2)

      assert can_create_users?(account) == true
    end

    test "returns false when seats limit is exceeded", %{account: account} do
      {:ok, account} =
        Domain.Accounts.update_account(account, %{
          limits: %{monthly_active_users_count: 1}
        })

      actor1 = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
      Fixtures.Clients.create_client(account: account, actor: actor1)
      Fixtures.Clients.create_client(account: account, actor: actor1)

      actor2 = Fixtures.Actors.create_actor(type: :account_user, account: account)
      Fixtures.Clients.create_client(account: account, actor: actor2)

      assert can_create_users?(account) == false
    end

    test "returns false when account is disabled", %{account: account} do
      {:ok, account} =
        Domain.Accounts.update_account(account, %{
          disabled_at: DateTime.utc_now(),
          disabled_reason: "Stripe subscription deleted"
        })

      assert can_create_users?(account) == false
    end

    test "returns true when seats limit is not set", %{account: account} do
      assert can_create_users?(account) == true
    end
  end

  describe "service_accounts_limit_exceeded?/2" do
    test "returns false when service accounts limit is not exceeded", %{account: account} do
      {:ok, account} =
        Domain.Accounts.update_account(account, %{
          limits: %{service_accounts_count: 10}
        })

      assert service_accounts_limit_exceeded?(account, 10) == false
    end

    test "returns true when service accounts limit is exceeded", %{account: account} do
      {:ok, account} =
        Domain.Accounts.update_account(account, %{
          limits: %{service_accounts_count: 10}
        })

      assert service_accounts_limit_exceeded?(account, 11) == true
    end

    test "returns true when service accounts limit is not set", %{account: account} do
      assert service_accounts_limit_exceeded?(account, 0) == false
    end
  end

  describe "can_create_service_accounts?/1" do
    test "returns true when service accounts limit is not exceeded", %{account: account} do
      {:ok, account} =
        Domain.Accounts.update_account(account, %{
          limits: %{service_accounts_count: 3}
        })

      actor1 = Fixtures.Actors.create_actor(type: :service_account, account: account)
      Fixtures.Clients.create_client(account: account, actor: actor1)
      Fixtures.Clients.create_client(account: account, actor: actor1)

      actor2 = Fixtures.Actors.create_actor(type: :service_account, account: account)
      Fixtures.Clients.create_client(account: account, actor: actor2)

      assert can_create_service_accounts?(account) == true
    end

    test "returns false when service accounts limit is exceeded", %{account: account} do
      {:ok, account} =
        Domain.Accounts.update_account(account, %{
          limits: %{service_accounts_count: 1}
        })

      actor1 = Fixtures.Actors.create_actor(type: :service_account, account: account)
      Fixtures.Clients.create_client(account: account, actor: actor1)
      Fixtures.Clients.create_client(account: account, actor: actor1)

      actor2 = Fixtures.Actors.create_actor(type: :service_account, account: account)
      Fixtures.Clients.create_client(account: account, actor: actor2)

      assert can_create_service_accounts?(account) == false
    end

    test "returns false when account is disabled", %{account: account} do
      {:ok, account} =
        Domain.Accounts.update_account(account, %{
          disabled_at: DateTime.utc_now(),
          disabled_reason: "Stripe subscription deleted"
        })

      assert can_create_service_accounts?(account) == false
    end

    test "returns true when service accounts limit is not set", %{account: account} do
      assert can_create_service_accounts?(account) == true
    end
  end

  describe "gateway_groups_limit_exceeded?/2" do
    test "returns false when gateway groups limit is not exceeded", %{account: account} do
      {:ok, account} =
        Domain.Accounts.update_account(account, %{
          limits: %{gateway_groups_count: 10}
        })

      assert gateway_groups_limit_exceeded?(account, 10) == false
    end

    test "returns true when gateway groups limit is exceeded", %{account: account} do
      {:ok, account} =
        Domain.Accounts.update_account(account, %{
          limits: %{gateway_groups_count: 10}
        })

      assert gateway_groups_limit_exceeded?(account, 11) == true
    end

    test "returns true when gateway groups limit is not set", %{account: account} do
      assert gateway_groups_limit_exceeded?(account, 0) == false
    end
  end

  describe "can_create_gateway_groups?/1" do
    test "returns true when gateway groups limit is not exceeded", %{account: account} do
      {:ok, account} =
        Domain.Accounts.update_account(account, %{
          limits: %{gateway_groups_count: 3}
        })

      Fixtures.Gateways.create_group(account: account)
      Fixtures.Gateways.create_group(account: account)
      Fixtures.Gateways.create_group()

      assert can_create_gateway_groups?(account) == true
    end

    test "returns false when gateway groups limit is exceeded", %{account: account} do
      {:ok, account} =
        Domain.Accounts.update_account(account, %{
          limits: %{gateway_groups_count: 1}
        })

      Fixtures.Gateways.create_group(account: account)

      assert can_create_gateway_groups?(account) == false
    end

    test "returns false when account is disabled", %{account: account} do
      {:ok, account} =
        Domain.Accounts.update_account(account, %{
          disabled_at: DateTime.utc_now(),
          disabled_reason: "Stripe subscription deleted"
        })

      assert can_create_gateway_groups?(account) == false
    end

    test "returns true when gateway groups limit is not set", %{account: account} do
      assert can_create_gateway_groups?(account) == true
    end
  end

  describe "admins_limit_exceeded?/2" do
    test "returns false when admins limit is not exceeded", %{account: account} do
      {:ok, account} =
        Domain.Accounts.update_account(account, %{
          limits: %{account_admin_users_count: 10}
        })

      assert admins_limit_exceeded?(account, 10) == false
    end

    test "returns true when admins limit is exceeded", %{account: account} do
      {:ok, account} =
        Domain.Accounts.update_account(account, %{
          limits: %{account_admin_users_count: 10}
        })

      assert admins_limit_exceeded?(account, 11) == true
    end

    test "returns true when admins limit is not set", %{account: account} do
      assert gateway_groups_limit_exceeded?(account, 0) == false
    end
  end

  describe "can_create_admin_users?/1" do
    test "returns true when admins limit is not exceeded", %{account: account} do
      {:ok, account} =
        Domain.Accounts.update_account(account, %{
          limits: %{account_admin_users_count: 5}
        })

      Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
      Fixtures.Actors.create_actor(type: :account_admin_user, account: account)

      assert can_create_admin_users?(account) == true
    end

    test "returns false when admins limit is exceeded", %{account: account} do
      {:ok, account} =
        Domain.Accounts.update_account(account, %{
          limits: %{account_admin_users_count: 1}
        })

      Fixtures.Actors.create_actor(type: :account_admin_user, account: account)

      assert can_create_admin_users?(account) == false
    end

    test "returns false when account is disabled", %{account: account} do
      {:ok, account} =
        Domain.Accounts.update_account(account, %{
          disabled_at: DateTime.utc_now(),
          disabled_reason: "Stripe subscription deleted"
        })

      assert can_create_admin_users?(account) == false
    end

    test "returns true when admins limit is not set", %{account: account} do
      assert can_create_admin_users?(account) == true
    end
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
      assert account.metadata.stripe.billing_email == "sub_1MowQVLkdIwHu7ixeRlqHVzs"

      assert_receive {:bypass_request, %{request_path: "/v1/customers"} = conn}
      assert conn.params == %{"name" => account.name, "metadata" => %{"account_id" => account.id}}
    end

    test "does nothing when account is already provisioned", %{account: account} do
      {:ok, account} =
        Domain.Accounts.update_account(account, %{
          metadata: %{stripe: %{customer_id: Ecto.UUID.generate()}}
        })

      assert provision_account(account) == {:ok, account}
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

    test "re-enables the account on subscription update", %{
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
          "service_accounts_count" => "unlimited",
          "gateway_groups_count" => 1
        }
      })

      subscription_metadata = %{
        "idp_sync" => "true",
        "multi_site_resources" => "true",
        "traffic_filters" => "false",
        "gateway_groups_count" => 5
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
               gateway_groups_count: 5,
               service_accounts_count: nil
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
