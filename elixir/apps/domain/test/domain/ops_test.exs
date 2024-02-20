defmodule Domain.OpsTest do
  use Domain.DataCase, async: true
  import Domain.Ops

  describe "provision_support_by_account_slug/1" do
    setup do
      Domain.Config.put_env_override(:outbound_email_adapter_configured?, true)
    end

    test "provisions support account by slug" do
      account = Fixtures.Accounts.create_account()
      Fixtures.Auth.create_email_provider(account: account)
      assert {:ok, {actor, identity}} = provision_support_by_account_slug(account.slug)

      assert actor.name == "Firezone Support"
      assert actor.account_id == account.id

      assert identity.provider_identifier == "ent-support@firezone.dev"
      assert identity.account_id == account.id
      assert identity.actor_id == actor.id
    end
  end

  describe "create_and_provision_account/1" do
    setup do
      Domain.Config.put_env_override(:outbound_email_adapter_configured?, true)
    end

    test "provisions an account when valid input is provided" do
      Bypass.open()
      |> Mocks.Stripe.mock_create_customer_endpoint(%{id: nil, name: "Test Account"})
      |> Mocks.Stripe.mock_create_subscription_endpoint()

      params = %{
        name: "Test Account",
        slug: "test_account",
        admin_name: "Test Admin",
        admin_email: "test_admin@firezone.local"
      }

      assert {:ok,
              %{
                account: account,
                provider: provider,
                actor: actor,
                identity: identity
              }} = create_and_provision_account(params)

      assert account.name == "Test Account"
      assert account.slug == "test_account"
      assert account.metadata.stripe.customer_id

      assert actor.name == "Test Admin"
      assert actor.account_id == account.id

      assert identity.provider_identifier == "test_admin@firezone.local"
      assert identity.account_id == account.id
      assert identity.actor_id == actor.id
      assert identity.provider_id == provider.id

      assert provider.name == "Email"
      assert provider.adapter == :email

      assert {:ok, account} = Domain.Accounts.fetch_account_by_id_or_slug("test_account")
      assert account.name == "Test Account"
      assert account.metadata.stripe.customer_id
    end

    test "returns an error when invalid input is provided" do
      params = %{
        name: "Test Account",
        slug: "test_account",
        admin_name: "Test Admin",
        admin_email: "invalid"
      }

      # create_and_provision_account/1 catches the invalid params and raises MatchError
      assert_raise MatchError, fn ->
        create_and_provision_account(params)
      end
    end
  end
end
