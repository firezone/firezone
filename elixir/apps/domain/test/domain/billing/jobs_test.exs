defmodule Domain.Billing.JobsTest do
  use Domain.DataCase, async: true
  import Domain.Billing.Jobs

  describe "check_account_limits/1" do
    setup do
      account = Fixtures.Accounts.create_account()

      %{
        account: account
      }
    end

    test "does nothing when limits are not violated", %{
      account: account
    } do
      assert check_account_limits(%{}) == :ok

      account = Repo.get!(Domain.Accounts.Account, account.id)
      refute account.warning
      assert account.warning_delivery_attempts == 0
      refute account.warning_last_sent_at
    end

    test "puts a warning for an account when limits are violated", %{
      account: account
    } do
      Domain.Accounts.update_account(account, %{
        limits: %{
          monthly_active_actors_count: 1,
          sites_count: 1,
          account_admin_users_count: 1
        }
      })

      Fixtures.Clients.create_client(account: account)
      Fixtures.Clients.create_client(account: account)

      Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
      Fixtures.Actors.create_actor(type: :account_admin_user, account: account)

      Fixtures.Gateways.create_group(account: account)
      Fixtures.Gateways.create_group(account: account)

      assert check_account_limits(%{}) == :ok

      account = Repo.get!(Domain.Accounts.Account, account.id)

      assert account.warning ==
               "You have exceeded the following limits: monthly active actors, sites, account admins."

      assert account.warning_delivery_attempts == 0
      assert account.warning_last_sent_at
    end
  end
end
