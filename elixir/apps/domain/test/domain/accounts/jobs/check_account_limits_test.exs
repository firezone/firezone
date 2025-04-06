defmodule Domain.Accounts.Jobs.CheckAccountLimitsTest do
  use Domain.DataCase, async: true
  import Domain.Accounts.Jobs.CheckAccountLimits

  describe "execute/1" do
    setup do
      account =
        Fixtures.Accounts.create_account(
          metadata: %{
            stripe: %{
              customer_id: "cus_123",
              subscription_id: "sub_123"
            }
          }
        )

      %{
        account: account
      }
    end

    test "does nothing when limits are not violated", %{
      account: account
    } do
      assert execute(%{}) == :ok

      account = Repo.get!(Domain.Accounts.Account, account.id)
      refute account.warning
      assert account.warning_delivery_attempts == 0
      refute account.warning_last_sent_at
    end

    test "puts a warning for an account when limits are violated", %{
      account: account
    } do
      Fixtures.Clients.create_client(account: account, actor: [type: :account_user])
      Fixtures.Clients.create_client(account: account, actor: [type: :account_user])

      Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
      Fixtures.Actors.create_actor(type: :account_admin_user, account: account)

      Fixtures.Actors.create_actor(type: :service_account, account: account)
      Fixtures.Actors.create_actor(type: :service_account, account: account)

      Fixtures.Gateways.create_group(account: account)
      Fixtures.Gateways.create_group(account: account)

      Domain.Accounts.update_account(account, %{
        limits: %{
          users_count: 1,
          monthly_active_users_count: 1,
          service_accounts_count: 1,
          gateway_groups_count: 1,
          account_admin_users_count: 1
        }
      })

      assert execute(%{}) == :ok

      account = Repo.get!(Domain.Accounts.Account, account.id)

      assert account.warning =~ "You have exceeded the following limits:"
      assert account.warning =~ "users"
      assert account.warning =~ "monthly active users"
      assert account.warning =~ "service accounts"
      assert account.warning =~ "sites"
      assert account.warning =~ "account admins"

      assert account.warning_delivery_attempts == 0
      assert account.warning_last_sent_at
    end
  end
end
